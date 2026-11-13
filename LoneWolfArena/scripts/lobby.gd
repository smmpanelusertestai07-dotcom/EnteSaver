class_name Lobby
extends Node3D
## Lobby: our character large on a lit hexagonal podium in a container yard at sunset (cheap
## 3D: a few boxes and props, fog, one shadowed light), in the middle; drag on it to turn it.
## UI in the reference lobby's layout (original art, nothing to buy: no currency, no store):
## the player card (profile picture, name + EDIT, level, XP line: a tap opens PROFILE) top-left;
## the logo, the ping chip, FRIENDS and the settings gear top-right; the bar of main buttons
## bottom-left (WARDROBE, ONLINE 1 VS 1); bottom-right the mode card (TRAINING GROUND with the
## bot's level or the target dummy, or LONE WOLF, on CARGO CAGE; a tap opens SELECT MODE, where
## the opponent and the team size SOLO / DUO / SQUAD are picked too; the figure at its right end
## opens the compact team-size box above it, LobbyDialogs.open_size_box) and the big START. START plays
## the card's mode at its size (start_route): TRAINING GROUND shows the match loading overlay
## (Loading.start_match) and enters the arena (DUO / SQUAD: the player and bot teammates against
## bots, TeamArena.offline_match); LONE WOLF searches for a random opponent (SOLO: QUICK MATCH,
## scripts/net_match.gd; DUO / SQUAD: Cloud.group_start, real players only, design/GROUPS.txt; in a
## group of two, SOLO is a DUEL between the two: start_duel). A search has no popup: the search tab
## (SearchTab, scripts/lobby_search.gd) drops from the top centre with the time searched and a
## cancel X, START turns into the greyed MATCHING... plate, and the lobby stays usable (a tap on the
## mode card says CANCEL THE SEARCH FIRST; the match found closes whatever window is open). In
## LONE WOLF the GROUP bar under the player card (LobbyTeam, scripts/lobby_team.gd) invites online
## friends into a group of up to 4; the other members stand on the podium beside the hero, smaller,
## with name plates and a LEADER mark (show_group_members); only the leader's START works (a member
## sees GroupWaitLeader "WAITING FOR <LEADER> TO START" in its place). WARDROBE opens the outfit picker
## (every outfit free: item cards, preview on the podium, EQUIP / BACK). CUSTOM HUD and HOW TO PLAY
## are in SETTINGS (the gear).
## This file has the 3D stage, the top bar, the bottom bar, the mode card, START, the settings
## panel and input. Four parts have their own files: helpers the lobby makes, which build under
## `ui` and reach back through their `lobby`: LobbyDialogs (`dialogs`: the popup frame, SELECT
## MODE with the opponent chips, the name editor, the quit dialog), LobbyFriends (`friends`:
## ONLINE 1 VS 1, FRIENDS, custom rooms, the net signals), LobbyWardrobe (`wardrobe_ui`: WARDROBE),
## LobbyProfile (`profile_ui`: PROFILE and another player's card) and LobbyTeam (`team`: the TEAM
## bar and its invites).
## Node names used by the screenshot walkthrough and the tests: StartButton, ModeCard (with
## SizeBoxButton), BottomBar,
## PodiumInvite (the podium's "+": a place to add a teammate, _build_podium_invite),
## BundlesButton (WARDROBE), OnlineButton (ONLINE 1 VS 1), FriendsButton (FRIENDS: the unread
## badge), SettingsButton, Bundle_<id>, EquipButton, GroupWaitLeader, MatchingPlate, SearchLayer
## with SearchTab (SearchLine, SearchTimer, SearchPlayers, SearchCancel); 3D: GroupMembers with
## GroupModel_<1..3> (CharacterModel), each with NamePlate and, on the leader, LeaderMark.

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
const HERO_X := 0.5
const WARD_X := 0.78
const MODEL_YAW := PI - 0.32
## The group's other members on the podium (GROUPS.txt 1): smaller than the hero, left and right
## behind it on the podium, the third behind on the right on the floor (clear of the GROUP bar on
## the left and of the mode card); each turned a little toward the middle.
const MEMBER_SCALE := 0.86
const MEMBER_SPOTS := [Vector3(-0.62, PODIUM_TOP, -0.5), Vector3(0.62, PODIUM_TOP, -0.5), Vector3(1.45, 0.0, -1.55)]
const MEMBER_YAWS := [PI - 0.02, PI - 0.5, PI - 0.62]
## Name plate and LEADER mark heights over a member's feet (the model's own units, before its scale).
const PLATE_Y := 2.02
const MARK_Y := 2.24
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
## The lobby's parts in their own files (see above).
var dialogs := LobbyDialogs.new(self)
var friends := LobbyFriends.new(self)
var wardrobe_ui := LobbyWardrobe.new(self)
var profile_ui := LobbyProfile.new(self)
var team := LobbyTeam.new(self)
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
## The hero's turn by a drag, kept while the game runs (the reference keeps the view's angle when
## you come back from a match); it does not swing back by itself.
static var hero_yaw := MODEL_YAW
var _name_label: Label
var _avatar_view: Control
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
## The group's other members on the podium: the node GroupMembers, id -> CharacterModel, id -> spot.
var group_view: Node3D
var _member_models := {}
var _member_slot := {}
var _group_gid := ""
## In START's place for a member: WAITING FOR <LEADER> TO START (or the group's search).
var _wait_leader: PanelContainer
var _wait_label: Label
var _gate_t := 0.0
var _gate_member := false
var _gate_leader_name := ""
## The search tab (SearchTab, scripts/lobby_search.gd) on its own layer over the lobby's windows,
## and the plate that stands in START's place while a search runs.
var search_tab: SearchTab
var _search_layer: CanvasLayer
var _matching: Button
var _search_was := ""
## The member the leader's DUEL challenge went to (start_duel), "" when none waits: MATCHING...
## stands in START's place until the match loads, or a notice says why not.
var _duel_with := ""
## The "+" plate on the podium (PodiumInvite): a place to add a teammate, right of the hero.
var _podium_invite: Button


func _ready() -> void:
	Game.team_match = {}             # a team match is set up by START or a team invite, never left over
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
	model.rotation.y = hero_yaw
	model.setup(String(Game.profile.bundle), false)
	model.play_lobby(true)          # the hero also cheers now and then
	group_view = Node3D.new()
	group_view.name = "GroupMembers"
	add_child(group_view)
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
	UI.keep_clear_of_cutout(_main_ui)          # the menus, cards and START stay out of a camera cutout
	var root := _main_ui
	# soft vignette so text reads over the 3D
	var top := UI.gradient_rect([[0.0, Color(0, 0, 0, 0.5)], [0.16, Color(0, 0, 0, 0.0)], [0.8, Color(0, 0, 0, 0.0)], [1.0, Color(0, 0, 0, 0.55)]])
	UI.full_rect(top)
	root.add_child(top)
	_build_top_bar(root)
	_build_right_column(root)
	_build_bottom_bar(root)
	_build_chat_strip(root)
	_build_add_button(root)
	team.build(root)
	_build_podium_invite(root)
	# The search tab hangs over everything the lobby opens (WARDROBE, PROFILE, SETTINGS, popups),
	# so the search stays in sight and its X in reach while the player looks around.
	_search_layer = CanvasLayer.new()
	_search_layer.name = "SearchLayer"
	_search_layer.layer = ui.layer + 1
	add_child(_search_layer)
	var holder := Control.new()
	UI.full_rect(holder)
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_search_layer.add_child(holder)
	UI.keep_clear_of_cutout(holder)
	search_tab = SearchTab.new()
	holder.add_child(search_tab)


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
	# The pencil: a 56 px touch target (a near miss would open PROFILE instead) around a plate that
	# fits next to the name.
	var edit := _pencil_button(Vector2(44, 38))
	edit.name = "EditName"
	edit.position = Vector2(238, 0)
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
	top_right.offset_bottom = 6 + UI.TOUCH_MIN
	top_right.alignment = BoxContainer.ALIGNMENT_END
	top_right.add_theme_constant_override("separation", 8)
	root.add_child(top_right)
	# FRIENDS (the FRIENDS tab of the ONLINE window; the unread badge sits on it) and the gear.
	var pals := UI.glyph_button("v_friends", UI.TOUCH_MIN, "FR")
	pals.name = "FriendsButton"
	pals.pressed.connect(_open_friends.bind("friends"))
	top_right.add_child(pals)
	var gear := UI.glyph_button("v_settings", UI.TOUCH_MIN, "SET")
	gear.name = "SettingsButton"
	gear.pressed.connect(_open_settings)
	top_right.add_child(gear)
	root.add_child(NetPing.lobby_chip())        # the round trip to the relay (scripts/net_ping.gd)


## The pencil (EDIT) button: a 56 px touch target (the 720 px canvas) with its plate drawn in the
## middle, `plate` px (all of it by default; smaller where there is no room for a 56 px plate).
func _pencil_button(plate := Vector2(56, 56)) -> Button:
	var b := Button.new()
	b.custom_minimum_size = Vector2(56, 56)
	b.size = Vector2(56, 56)
	b.focus_mode = Control.FOCUS_NONE
	var looks := {
		"normal": UI.chamfer(Color(1, 1, 1, 0.08), 4, 1, Color(1, 1, 1, 0.25), 0.0, ["br"]),
		"hover": UI.chamfer(Color(1, 1, 1, 0.16), 4, 1, Color(1, 1, 1, 0.4), 0.0, ["br"]),
		"pressed": UI.chamfer(Color(UI.ACCENT, 0.4), 4, 1, UI.ACCENT, 0.0, ["br"]),
	}
	for st: String in ["normal", "hover", "pressed", "hover_pressed", "focus"]:
		b.add_theme_stylebox_override(st, StyleBoxEmpty.new())
	b.draw.connect(func() -> void:
		var mode := b.get_draw_mode()
		var look: StyleBox = looks.normal
		if mode == BaseButton.DRAW_PRESSED or mode == BaseButton.DRAW_HOVER_PRESSED:
			look = looks.pressed
		elif mode == BaseButton.DRAW_HOVER:
			look = looks.hover
		var ps := plate.min(b.size)
		look.draw(b.get_canvas_item(), Rect2(((b.size - ps) * 0.5).round(), ps))
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


## The bar of main buttons bottom-left, as the reference lobby's: WARDROBE and ONLINE 1 VS 1, a
## glyph and a caption each with a thin divider between, on a dark translucent strip.
func _build_bottom_bar(root: Control) -> void:
	var bar := PanelContainer.new()
	bar.name = "BottomBar"
	var st := UI.chamfer(Color(0.02, 0.02, 0.025, 0.62), 12, 1, Color(1, 1, 1, 0.14), 0.0, ["tr"])
	st.content_margin_left = 6
	st.content_margin_right = 16
	bar.add_theme_stylebox_override("panel", st)
	bar.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT, Control.PRESET_MODE_MINSIZE)
	bar.offset_left = 12
	bar.offset_bottom = -12
	bar.grow_vertical = Control.GROW_DIRECTION_BEGIN
	root.add_child(bar)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	bar.add_child(row)
	var items := [
		["WARDROBE", "v_wardrobe", "BundlesButton", _open_wardrobe],
		["PROFILE", "v_profile", "ProfileButton", _open_profile],
		["ONLINE 1 VS 1", "v_online", "OnlineButton", _open_friends.bind("online")],
	]
	for i in items.size():
		if i > 0:
			var line := ColorRect.new()
			line.color = Color(1, 1, 1, 0.22)
			line.custom_minimum_size = Vector2(1, 26)
			line.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			line.mouse_filter = Control.MOUSE_FILTER_IGNORE
			row.add_child(line)
		var it: Array = items[i]
		row.add_child(_bar_button(String(it[0]), String(it[1]), String(it[2]), it[3]))


## The chat strip above the bottom bar (the reference's chat icons and one-line ticker): a speech
## bubble button (ChatButton) and the newest friend message as "[FRIEND] NAME: text" (ChatTicker,
## "[FRIENDS] TAP TO CHAT WITH A FRIEND" when there is none); a tap opens the chat panel with that
## friend, or FRIENDS when there is nobody to chat with yet.
func _build_chat_strip(root: Control) -> void:
	var strip := Button.new()
	strip.name = "ChatStrip"
	strip.focus_mode = Control.FOCUS_NONE
	strip.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	strip.offset_left = 12
	strip.offset_right = 12 + 470
	strip.offset_top = -12 - UI.TOUCH_MIN - 8 - UI.TOUCH_MIN      # a full 56 px touch target
	strip.offset_bottom = -12 - UI.TOUCH_MIN - 8
	for st: String in ["normal", "hover", "pressed", "hover_pressed", "focus"]:
		strip.add_theme_stylebox_override(st, StyleBoxEmpty.new())
	var ticker := UI.ellipsis(UI.label("", 17, UI.TEXT, "semi"))
	ticker.name = "ChatTicker"
	UI.outlined(ticker, 3, Color(0, 0, 0, 0.6))
	ticker.position = Vector2(62, 0)
	ticker.size = Vector2(404, UI.TOUCH_MIN)
	ticker.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	strip.add_child(ticker)
	strip.draw.connect(func() -> void:
		var hot := strip.is_pressed()
		var r := Rect2(0, (strip.size.y - 44.0) * 0.5, 52, 44)     # the icon square, centred
		strip.draw_rect(r, Color(0, 0, 0, 0.62) if not hot else Color(UI.ACCENT, 0.35))
		strip.draw_rect(r, Color(1, 1, 1, 0.22), false, 1.0)
		# our speech bubble: a rounded box with a tail and three dots
		var b := Rect2(r.position + Vector2(11, 9), Vector2(30, 21))
		strip.draw_rect(b, UI.TEXT)
		strip.draw_colored_polygon(PackedVector2Array([b.position + Vector2(6, b.size.y), b.position + Vector2(15, b.size.y),
			b.position + Vector2(5, b.size.y + 8)]), UI.TEXT)
		for i in 3:
			strip.draw_circle(b.position + Vector2(8 + i * 7, b.size.y * 0.5), 2.2, UI.INK)
		strip.draw_rect(Rect2(58, strip.size.y * 0.5 - 12, 2, 24), Color(1, 1, 1, 0.5))
		var n := NetChat.unread_total() + _group_unread()
		if n > 0:
			strip.draw_circle(r.position + Vector2(48, 4), 9.0, UI.BAD)
			strip.draw_string(UI.font("bold"), r.position + Vector2(39, 9), str(mini(n, 9)), HORIZONTAL_ALIGNMENT_CENTER, 18, 13, Color.WHITE))
	strip.pressed.connect(func() -> void:
		Audio.play("ui_click", -4.0)
		var who := chat_ticker_friend()
		if Game.cloud and Game.cloud.in_group():
			LobbyNet.open_group(self)          # in a team (or a room): its chat first, as the reference's
		elif who == "":
			_open_friends("friends")
		else:
			LobbyNet.open(self, who, String(Game.profile.friends[who].name), ""))
	root.add_child(strip)
	_refresh_chat_strip()


## The friend the chat strip opens: the newest message's (unread first), else the first friend
## online, else the first friend; "" with no friends (not blocked).
func chat_ticker_friend() -> String:
	var best := ""
	var best_ts := -1
	for f: String in Game.profile.friends:
		if Game.is_blocked(f):
			continue
		var msgs := NetChat.messages(f)
		var ts := int((msgs.back() as Array)[0]) if not msgs.is_empty() else -1
		if NetChat.unread(f) > 0:
			ts += 1 << 40
		if ts > best_ts or best == "":
			best = f
			best_ts = ts
	return best


var _chat_shown := ""
var _chat_t := 0.0


## The ticker follows the newest friend message (checked twice a second from _process).
func _refresh_chat_strip() -> void:
	var strip := _main_ui.get_node_or_null("ChatStrip") as Button if _main_ui else null
	if strip == null:
		return
	var who := chat_ticker_friend()
	var text := "[FRIENDS] TAP TO CHAT WITH A FRIEND"
	if who != "":
		var msgs := NetChat.messages(who)
		if not msgs.is_empty():
			var m: Array = msgs.back()
			text = "[FRIEND] %s: %s" % [String(Game.profile.name) if bool(m[1]) else String(Game.profile.friends[who].name),
				NetChat.first_words(String(m[2]), 40)]
	if Game.cloud and Game.cloud.in_group():
		# In a team (or a custom room): its newest line, or how to start one.
		var gm := NetChat.group_messages(String(Game.cloud.group.get("gid", "")))
		var tag := LobbyNet.group_title()
		text = "[%s] TAP TO CHAT WITH YOUR %s" % [tag, tag]
		if not gm.is_empty():
			var g: Array = gm.back()
			text = "[%s] %s: %s" % [tag, String(g[2]), NetChat.first_words(String(g[3]), 40)]
	var key := text + "|" + str(NetChat.unread_total() + _group_unread())
	if key == _chat_shown:
		return
	_chat_shown = key
	(strip.get_node("ChatTicker") as Label).text = text
	strip.queue_redraw()


## The TEAM / ROOM chat's unread lines (0 out of a group).
func _group_unread() -> int:
	if Game.cloud == null or not Game.cloud.in_group():
		return 0
	return NetChat.group_unread(String(Game.cloud.group.get("gid", "")))


## ADD (right side, as the reference's add-friend button): a person with a plus over its caption;
## opens FRIENDS on PLAYERS, where every player can be added.
func _build_add_button(root: Control) -> void:
	var b := Button.new()
	b.name = "AddFriendButton"
	b.focus_mode = Control.FOCUS_NONE
	b.set_anchors_and_offsets_preset(Control.PRESET_CENTER_RIGHT)
	b.offset_left = -84
	b.offset_right = -14
	b.offset_top = -10
	b.offset_bottom = 60
	for st: String in ["normal", "hover", "pressed", "hover_pressed", "focus"]:
		b.add_theme_stylebox_override(st, StyleBoxEmpty.new())
	b.draw.connect(func() -> void:
		var col := UI.ACCENT if b.is_pressed() else UI.TEXT
		HudDraw.icon(b, HudDraw.tex("v_friend_add"), Vector2(b.size.x * 0.5, 22), Vector2(36, 36), col)
		var f := UI.font("heavy")
		b.draw_string_outline(f, Vector2(0, 60), "ADD", HORIZONTAL_ALIGNMENT_CENTER, b.size.x, 18, 4, Color(0, 0, 0, 0.6))
		b.draw_string(f, Vector2(0, 60), "ADD", HORIZONTAL_ALIGNMENT_CENTER, b.size.x, 18, col))
	b.button_down.connect(b.queue_redraw)
	b.button_up.connect(b.queue_redraw)
	b.pressed.connect(func() -> void:
		Audio.play("ui_click", -4.0)
		_open_friends("online"))
	root.add_child(b)


## One button of the bottom bar: the glyph and the caption, white, accent while pressed.
func _bar_button(text: String, icon_name: String, node_name: String, action: Callable) -> Button:
	var b := Button.new()
	b.name = node_name
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(0, UI.TOUCH_MIN)
	b.text = text
	b.icon = UI.icon_texture(icon_name)
	b.add_theme_constant_override("icon_max_width", 28)      # (not expanded: its width counts in the button's)
	b.add_theme_constant_override("h_separation", 10)
	b.add_theme_font_override("font", UI.font("bold"))
	b.add_theme_font_size_override("font_size", 22)
	var flat := UI.box(Color(0, 0, 0, 0), 0, 0, Color.TRANSPARENT, 0.0)
	flat.content_margin_left = 16
	flat.content_margin_right = 16
	var lit := flat.duplicate() as StyleBoxFlat
	lit.bg_color = Color(1, 1, 1, 0.08)
	for state in ["normal", "focus"]:
		b.add_theme_stylebox_override(state, flat)
	for state in ["hover", "pressed", "hover_pressed"]:
		b.add_theme_stylebox_override(state, lit)
	b.add_theme_color_override("font_color", UI.TEXT)
	b.add_theme_color_override("font_hover_color", UI.TEXT)
	b.add_theme_color_override("font_pressed_color", UI.ACCENT)
	b.add_theme_color_override("font_hover_pressed_color", UI.ACCENT)
	b.add_theme_constant_override("outline_size", 3)
	b.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.5))
	b.add_theme_color_override("icon_normal_color", UI.TEXT)
	b.add_theme_color_override("icon_hover_color", UI.TEXT)
	b.add_theme_color_override("icon_pressed_color", UI.ACCENT)
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
	# A member's phone shows who starts in START's place (GROUPS.txt 1).
	_wait_leader = PanelContainer.new()
	_wait_leader.name = "GroupWaitLeader"
	_wait_leader.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
	_wait_leader.offset_left = -342
	_wait_leader.offset_top = -90
	_wait_leader.offset_right = -12
	_wait_leader.offset_bottom = -12
	_wait_leader.add_theme_stylebox_override("panel", UI.chamfer(Color(0.02, 0.02, 0.025, 0.8), 12, 2, Color(UI.ACCENT, 0.7), 10.0, ["tl", "br"]))
	_wait_leader.mouse_filter = Control.MOUSE_FILTER_STOP
	_wait_leader.visible = false
	_wait_label = UI.label("", 21, UI.ACCENT, "heavy")
	_wait_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_wait_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_wait_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_wait_leader.add_child(_wait_label)
	root.add_child(_wait_leader)
	# While a search runs, START is a greyed plate (the search tab at the top cancels it).
	_matching = UI.hero_button("MATCHING...", 40, Vector2(330, 78))
	_matching.name = "MatchingPlate"
	_matching.disabled = true
	_matching.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
	_matching.offset_left = -342
	_matching.offset_top = -90
	_matching.offset_right = -12
	_matching.offset_bottom = -12
	_matching.visible = false
	root.add_child(_matching)
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
		if search_kind() != "":
			dialogs.notice("SELECT MODE", "CANCEL THE SEARCH FIRST")
			return
		_select_mode())
	root.add_child(mode_card)
	var text := VBoxContainer.new()
	text.position = Vector2(20, 2)
	text.add_theme_constant_override("separation", -4)
	text.mouse_filter = Control.MOUSE_FILTER_IGNORE
	mode_card.add_child(text)
	_mode_label = UI.shadowed(UI.label("", 32, UI.TEXT, "heavy"))
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
	mode_card.add_child(_build_size_box_button())
	_refresh_mode()


## The figure at the mode card's right end (SizeBoxButton, over the art's right part): a tap opens
## the team-size box just above the card (LobbyDialogs.open_size_box) instead of SELECT MODE.
## Hidden for a group member and during a search (update_start_gate).
func _build_size_box_button() -> Button:
	var b := Button.new()
	b.name = "SizeBoxButton"
	b.focus_mode = Control.FOCUS_NONE
	b.set_anchors_and_offsets_preset(Control.PRESET_RIGHT_WIDE)
	b.offset_left = -UI.TOUCH_MIN - 2.0
	b.offset_right = -2.0
	for st in ["normal", "hover", "pressed", "hover_pressed", "focus"]:
		b.add_theme_stylebox_override(st, StyleBoxEmpty.new())
	b.draw.connect(func() -> void:
		var c := b.size * 0.5
		var hot := b.is_hovered() or b.is_pressed() or dialogs.size_box != null
		b.draw_circle(c, 21.0, Color(0, 0, 0, 0.72), true, -1.0, true)
		b.draw_circle(c, 21.0, UI.ACCENT if hot else Color(1, 1, 1, 0.5), false, 2.0, true)
		HudDraw.icon(b, HudDraw.tex("v_player"), c, Vector2(26, 26), UI.ACCENT if hot else Color.WHITE))
	for sig in ["mouse_entered", "mouse_exited", "button_down", "button_up"]:
		b.connect(sig, b.queue_redraw)
	b.pressed.connect(func() -> void:
		Audio.play("ui_click", -4.0)
		if dialogs.size_box:
			dialogs.close_size_box()
		else:
			dialogs.open_size_box()
		b.queue_redraw())
	return b


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
	var purple := Color(0.37, 0.21, 0.58, a)        # (#5E3595)
	var blue := Color(0.23, 0.33, 0.77, a)          # (#3B55C4)
	c.draw_polygon(pts, PackedColorArray([purple, purple.lerp(blue, 0.6), blue, blue.lerp(purple, 0.3), purple]))
	c.draw_rect(Rect2(0, 0, s.x * 0.55, s.y), Color(0, 0, 0, 0.18))
	var thumb := Rect2(s.x - 128, 6, 120, s.y - 12)
	draw_mode_art(c, Game.mode, thumb)
	c.draw_rect(thumb, Color(1, 1, 1, 0.35), false, 1.5)
	# a dropdown chevron beside the mode name: tap to choose the other mode
	var hot := c.is_hovered() or c.is_pressed()
	var cx := s.x - 150.0
	c.draw_polyline(PackedVector2Array([Vector2(cx - 9, 18), Vector2(cx, 27), Vector2(cx + 9, 18)]),
		UI.ACCENT if hot else Color(1, 1, 1, 0.8), 3.0, true)
	var frame := pts.duplicate()
	frame.append(pts[0])
	c.draw_polyline(frame, UI.ACCENT if not hot else UI.ACCENT.lightened(0.3), 2.0, true)


## The mode card follows Game.mode and the opponent chosen in SELECT MODE (the bot's level, or
## Game.practice: the target dummy).
func _refresh_mode() -> void:
	_mode_label.text = Game.mode_name()
	_mode_sub.text = mode_format()
	mode_card.queue_redraw()
	team.refresh()


## The mode card's format line (short: the card's art is beside it): LONE WOLF "1 VS 1 ONLINE"
## (DUO / SQUAD: "DUO  ·  2 VS 2 ONLINE", or "DUO: NEXT UPDATE" while Game.TEAMS_ONLINE is off);
## TRAINING GROUND "BOT: <level>  ·  FIRST TO n" (DUO / SQUAD: "SQUAD  ·  BOT: <level>"), or
## "TARGET DUMMY".
static func mode_format(teams_online := Game.TEAMS_ONLINE) -> String:
	var size := Game.team_size
	var word := String(LobbyDialogs.SIZE_NAMES.get(size, "SOLO"))
	if Game.mode != "training":
		if size == 1:
			return "1 VS 1 ONLINE"
		return "%s  ·  %d VS %d ONLINE" % [word, size, size] if teams_online else "%s: NEXT UPDATE" % word
	var level := String(Game.DIFFICULTY_NAMES[clampi(int(Game.settings.difficulty), 0, Game.DIFFICULTY_NAMES.size() - 1)])
	if size > 1:
		return "%s  ·  BOT: %s" % [word, level]
	if Game.practice:
		return "TARGET DUMMY"
	return "BOT: %s  ·  FIRST TO %d" % [level, Game.rounds_to_win()]


## The player card top-left follows the profile (PROFILE picks the picture, the editor the name).
func refresh_player_card() -> void:
	_name_label.text = String(Game.profile.name)
	if _avatar_view:
		_avatar_view.queue_redraw()


## START plays the mode on the card at its team size (start_route): TRAINING GROUND loads the
## match at once (SOLO: against the bot or the target dummy; DUO / SQUAD: the player and bot
## teammates against bots); LONE WOLF searches for a random opponent (SOLO: QUICK MATCH, NetMatch;
## DUO / SQUAD: TeamMatch, which plays against bots when nobody is found). The match loads once
## another searching player is found. Friends' duels and custom rooms are in the ONLINE window
## (FRIENDS top-right); a friend joins a DUO / SQUAD through the TEAM bar.
func _start() -> void:
	if start_btn.disabled or LobbyTeam.is_member():
		return                          # (a member's START is the leader's: GroupWaitLeader shows instead)
	var size := Game.team_size
	match start_route(Game.mode, size, Game.TEAMS_ONLINE, LobbyTeam.members().size()):
		"quick":
			if LobbyTeam.in_group():
				dialogs.notice("LONE WOLF 1 VS 1", "EXIT GROUP to play 1 VS 1, or pick DUO or SQUAD in SELECT MODE to play with your group.")
				return
			Game.team_match = {}
			NetMatch.open(self)
		"duel":
			start_duel()
		"team_search":
			start_group(size)
		"team_later":
			dialogs.notice("ONLINE DUO / SQUAD", "Online DUO and SQUAD come in the next update. Play them now in TRAINING GROUND, you and bot teammates against bots.")
		"training_team":
			Game.team_match = TeamArena.offline_match(size, "training", int(Game.settings.difficulty))
			load_match()
		_:
			Game.team_match = {}
			load_match()


## LONE WOLF DUO / SQUAD (GROUPS.txt 1): the leader (or a solo, who leads itself) starts the group's
## match or its search for real players (Cloud.group_start); a text back is a notice (a group of 3 in
## DUO...). Searching: the search tab with PLAYERS n/N (search_kind "group").
func start_group(size: int) -> void:
	Game.team_match = {}
	var word := String(LobbyDialogs.SIZE_NAMES.get(size, "DUO"))
	var why := Game.cloud_service().group_start(size)
	if why != "":
		dialogs.notice("LONE WOLF %s" % word, why)


## A group of exactly two with SOLO: the leader's START plays the plain 1 vs 1 between the two
## (Cloud.group_duel: a duel challenge the member's phone takes at once from its leader); the match
## and its results are the usual 1 vs 1's, and both come back to the lobby still in the group.
## Meanwhile the greyed MATCHING... plate stands in START's place (duel_waiting) until the match
## loads; a duel the member's phone never takes (declined, not reached, timed out) gives the plate
## back to START with a notice.
func start_duel() -> void:
	Game.team_match = {}
	var cloud := Game.cloud_service()
	var why := cloud.group_duel()
	if why != "":
		dialogs.notice("DUEL", why)
		return
	_duel_with = cloud.waiting_for()
	update_start_gate()


## True while the leader's DUEL challenge waits for the member's phone or its match is starting;
## once it ended otherwise, false and a notice (unless another one, such as COULD NOT BE REACHED,
## is already up).
func duel_waiting() -> bool:
	if _duel_with == "":
		return false
	var c := Game.cloud_service()
	if c.in_session or c.waiting_for_id() != "":
		return true
	var who := _duel_with
	_duel_with = ""
	if not start_btn.disabled and dialogs.modal == null:
		dialogs.notice("DUEL", "%s did not take the duel: it did not start." % who)
	return false


## What the lobby is searching for now: "quick" (the 1 vs 1 QUICK MATCH, NetMatch), "group" (a DUO
## / SQUAD search: Cloud.search_needed > 0, on the leader's phone and every member's), "" nothing.
func search_kind() -> String:
	var nm := get_node_or_null(^"NetMatch") as NetMatch
	if nm and nm.searching:
		return "quick"
	if Game.cloud and Game.cloud.search_needed > 0 and not Game.cloud.in_session and not Game.cloud.session_multi:
		return "group"
	return ""


## The search tab's X and Android back: the search stops (a member's search is the leader's).
func cancel_search() -> void:
	match search_kind():
		"quick":
			(get_node(^"NetMatch") as NetMatch).cancel()
		"group":
			if not LobbyTeam.is_member():
				friends.cancel_search()


## Every frame: the search tab follows what searches (shown, its X, the time, PLAYERS n/N).
func _follow_search(delta: float) -> void:
	if search_tab == null:
		return
	var kind := search_kind()
	if kind == "":
		search_tab.end()
		_search_was = ""
		return
	if kind != _search_was:
		search_tab.end()             # (a new kind of search counts from 0:00)
		_search_was = kind
	var member := kind == "group" and LobbyTeam.is_member()
	search_tab.begin(Callable() if member else cancel_search)
	var c := Game.cloud_service()
	if kind == "quick":
		var nm := get_node(^"NetMatch") as NetMatch
		search_tab.elapsed = nm.elapsed
		search_tab.set_status(nm.status_line())
		search_tab.set_players(0, 0)
	else:
		search_tab.elapsed += delta
		search_tab.set_status("CONNECTING..." if c.status != "online" else "")
		search_tab.set_players(c.search_found, c.search_needed)
	search_tab.refresh()


## A match was found: every window on the lobby goes (a popup, SETTINGS, PROFILE, WARDROBE), so
## the match loads in their place. SETTINGS closes as its own X closes it (SettingsPanel.close_panel:
## saved, its `closed` emitted; nothing in the lobby waits on that signal, the ping chip and the
## lobby's back handling read the tree), except while it runs DELETE MY DATA (busy), which keeps
## its waiting screen until the scene changes.
func close_layers() -> void:
	dialogs.close_size_box()
	dialogs.close_modal()
	var sp := _find_settings()
	if sp:
		sp.close_panel()
	if profile_ui.layer:
		profile_ui.close()
	if wardrobe:
		model.apply_bundle(String(Game.profile.bundle))
		_close_wardrobe()


## The group changed (Cloud.group_changed): a member's mode card follows the leader's choice, the
## leader's choice goes to a new group, then the GROUP bar, the podium and START's place follow.
func on_group_changed() -> void:
	var g := LobbyTeam.group()
	var gid := String(g.get("gid", ""))
	if LobbyTeam.is_member():
		var m := String(g.get("mode", Game.mode))
		var n := int(g.get("size", Game.team_size))
		if Game.MODE_NAMES.has(m) and n in Game.TEAM_SIZES and (m != Game.mode or n != Game.team_size):
			Game.mode = m
			Game.team_size = n
			_refresh_mode()
	elif gid != "" and gid != _group_gid:
		# (set first: set_group_mode emits group_changed at once, which comes back here; with the
		# gid not yet remembered that recursed without end, the crash on the first INVITE)
		_group_gid = gid
		Game.cloud_service().set_group_mode(Game.mode, Game.team_size)
	_group_gid = gid
	var list := LobbyTeam.members()
	_gate_member = LobbyTeam.is_member()
	_gate_leader_name = LobbyTeam.leader_name(list)
	team.on_group_changed()
	show_group_members(list)
	update_start_gate()


## START or, for a member, who starts in its place; while a search runs (search_kind) the greyed
## MATCHING... plate (MatchingPlate) for everyone, the leader's and a member's phone alike (the
## search tab at the top shows the rest), and on the leader's phone while its DUEL waits
## (duel_waiting). Polled 4 times a second.
func update_start_gate() -> void:
	if _wait_leader == null:
		return
	var searching := search_kind() != ""
	var text := ""
	if _gate_member and not searching:
		text = LobbyTeam.start_gate_text(true, false, _gate_leader_name)
	if _wait_label.text != text:
		_wait_label.text = text
	_wait_leader.visible = text != ""
	_matching.visible = (searching or duel_waiting()) and not start_btn.disabled
	start_btn.visible = text == "" and not _matching.visible
	var box_ok := LobbyDialogs.size_box_allowed(_gate_member, searching)
	var fig := mode_card.get_node_or_null(^"SizeBoxButton") as Control if mode_card else null
	if fig:
		fig.visible = box_ok
	if not box_ok:
		dialogs.close_size_box()


## The "+" plate on the podium (PodiumInvite, GROUPS.txt 1): while the group has room and this
## player may invite (the leader, or a solo in LONE WOLF), a small plate in the lobby's chamfered
## style floats at chest height over the first free member spot right of the hero (INVITE_SPOTS);
## a tap opens the same INVITE list as the GROUP bar's + INVITE. Hidden during a search and while
## the leader's DUEL waits (both show MATCHING...), in a CUSTOM ROOM, with the wardrobe open, and when both right spots are taken.
const INVITE_SPOTS := [1, 2]
const INVITE_PLATE := Vector2(64, 64)
const INVITE_LIFT := 1.05


func _build_podium_invite(root: Control) -> void:
	var b := Button.new()
	b.name = "PodiumInvite"
	b.text = "+"
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = INVITE_PLATE
	b.size = INVITE_PLATE
	b.add_theme_font_override("font", UI.font("heavy"))
	b.add_theme_font_size_override("font_size", 40)
	for st: String in ["font_color", "font_focus_color"]:
		b.add_theme_color_override(st, UI.ACCENT)
	for st: String in ["font_hover_color", "font_pressed_color", "font_hover_pressed_color"]:
		b.add_theme_color_override(st, UI.INK)
	var normal := UI.chamfer(Color(0.02, 0.02, 0.025, 0.62), 10, 2, Color(UI.ACCENT, 0.8), 0.0, ["tl", "br"])
	var lit := UI.chamfer(UI.ACCENT, 10, 2, UI.ACCENT, 0.0, ["tl", "br"])
	for st: String in ["normal", "focus"]:
		b.add_theme_stylebox_override(st, normal)
	for st: String in ["hover", "pressed", "hover_pressed"]:
		b.add_theme_stylebox_override(st, lit)
	b.visible = false
	b.pressed.connect(func() -> void:
		Audio.play("ui_click", -4.0)
		team.open_list())
	root.add_child(b)
	_podium_invite = b


## Whether the podium's "+" plate shows: the GROUP bar shows (`bar_shown`, not in a room), this
## player may invite (the leader or a solo) into a group with room, and no search runs.
static func podium_invite_shown(bar_on: bool, leader: bool, count: int, max_n: int, searching: bool) -> bool:
	return bar_on and leader and count < max_n and not searching


## The member spot the "+" plate stands over: the first of INVITE_SPOTS no member takes (`taken`:
## id -> spot, as member_slots gives), -1 when both are taken.
static func podium_invite_spot(taken: Dictionary) -> int:
	for i: int in INVITE_SPOTS:
		if not taken.values().has(i):
			return i
	return -1


## Every frame: the "+" plate's place over its spot (the camera's projection) and whether it shows.
func _follow_podium_invite() -> void:
	if _podium_invite == null or camera == null:
		return
	var cloud := Game.cloud_service()
	var grouped := LobbyTeam.in_group()
	var spot := podium_invite_spot(_member_slot)
	var on := wardrobe == null and _cam_t >= 1.0 and spot >= 0 and not start_btn.disabled and not cloud.in_room() \
		and podium_invite_shown(LobbyTeam.bar_shown(Game.mode, grouped), LobbyTeam.is_leader(),
			LobbyTeam.members().size() if grouped else 1, LobbyTeam.group_max(), search_kind() != "" or _duel_with != "")
	if on:
		var p: Vector3 = MEMBER_SPOTS[spot] + Vector3(0, INVITE_LIFT, 0)
		on = not camera.is_position_behind(p)
		var at := camera.unproject_position(p) - INVITE_PLATE * 0.5
		# never over the mode card or START (they sit bottom-right)
		if mode_card and mode_card.is_visible_in_tree():
			at.y = minf(at.y, mode_card.get_global_rect().position.y - INVITE_PLATE.y - 8.0)
		_podium_invite.global_position = at.round()
	if _podium_invite.visible != on:
		_podium_invite.visible = on


## Which of the 3 spots each other member takes: a member keeps theirs while in the group, a new one
## takes the first free spot; at most MEMBER_SPOTS.size(). `ids`: the other members, join order.
static func member_slots(old: Dictionary, ids: Array) -> Dictionary:
	var out := {}
	for id: String in ids:
		if old.has(id) and int(old[id]) < MEMBER_SPOTS.size():
			out[id] = int(old[id])
	for id: String in ids:
		if out.has(id):
			continue
		for i in MEMBER_SPOTS.size():
			if not out.values().has(i):
				out[id] = i
				break
	return out


## The other members on the podium (group_members, without this player): added with a short
## scale-in, dropped with a scale-out, their outfit changed in place; the name plate and the
## LEADER mark follow. They share the hero's materials and cast no shadow (the phone's budget).
func show_group_members(list: Array) -> void:
	if group_view == null:
		return
	var others: Array = []
	var info := {}
	for m: Dictionary in list:
		var id := String(m.get("id", ""))
		if bool(m.get("me", false)) or id == "" or others.size() >= MEMBER_SPOTS.size():
			continue
		others.append(id)
		info[id] = m
	_member_slot = member_slots(_member_slot, others)
	for id: String in _member_models.keys():
		if not info.has(id):
			_drop_member(id)
	for id: String in others:
		var m: Dictionary = info[id]
		var bundle := String(m.get("bundle", "default"))
		var cm := _member_models.get(id) as CharacterModel
		if cm == null or not is_instance_valid(cm):
			cm = _add_member(id, int(_member_slot[id]), bundle)
		elif cm.bundle != bundle:
			cm.apply_bundle(bundle)
		var plate := cm.get_node_or_null(^"NamePlate") as Label3D
		if plate:
			plate.text = String(m.get("name", "PLAYER"))
		var mark := cm.get_node_or_null(^"LeaderMark") as Label3D
		if mark:
			mark.visible = bool(m.get("leader", false))


func _add_member(id: String, slot: int, bundle: String) -> CharacterModel:
	var cm := CharacterModel.new()
	cm.name = "GroupModel_%d" % (slot + 1)
	group_view.add_child(cm)
	cm.position = MEMBER_SPOTS[slot]
	cm.rotation.y = MEMBER_YAWS[slot]
	cm.setup(bundle, false)
	cm.play_lobby()
	_share_looks(cm)
	var plate := _plate("PLAYER", UI.TEXT, 44, PLATE_Y)
	plate.name = "NamePlate"
	cm.add_child(plate)
	var mark := _plate("LEADER", UI.ACCENT, 34, MARK_Y)
	mark.name = "LeaderMark"
	cm.add_child(mark)
	cm.scale = Vector3.ONE * 0.01
	cm.create_tween().tween_property(cm, "scale", Vector3.ONE * MEMBER_SCALE, 0.3).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_member_models[id] = cm
	return cm


func _drop_member(id: String) -> void:
	var cm := _member_models.get(id) as CharacterModel
	_member_models.erase(id)
	if cm == null or not is_instance_valid(cm):
		return
	cm.name = "GroupModelGone"
	var tw := cm.create_tween()
	tw.tween_property(cm, "scale", Vector3.ONE * 0.01, 0.2).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_IN)
	tw.tween_callback(cm.queue_free)


## A member's meshes take the hero's materials (the same GLB meshes: one set of materials for every
## model on the podium) and cast no shadow.
func _share_looks(cm: CharacterModel) -> void:
	for n: String in cm.meshes:
		var mine := cm.meshes[n] as MeshInstance3D
		mine.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var hero := model.meshes.get(n) as MeshInstance3D if model else null
		if hero == null or hero.mesh != mine.mesh:
			continue
		for s in mine.mesh.get_surface_count():
			var mat := hero.get_surface_override_material(s)
			if mat:
				mine.set_surface_override_material(s, mat)


## A floating text over a member (always facing the camera, drawn over the yard).
static func _plate(text: String, color: Color, font_size: int, y: float) -> Label3D:
	var l := Label3D.new()
	l.text = text
	l.font = UI.font("heavy")
	l.font_size = font_size
	l.outline_size = 12
	l.modulate = color
	l.outline_modulate = Color(0, 0, 0, 0.85)
	l.pixel_size = 0.004
	l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	l.no_depth_test = true
	l.double_sided = true
	l.render_priority = 10
	l.outline_render_priority = 9
	l.position = Vector3(0, y, 0)
	return l


## What START does for a mode and a team size: "training" (the 1 vs 1 against the bot or the
## dummy), "training_team" (DUO / SQUAD against bots on this phone), "quick" (the 1 vs 1 QUICK
## MATCH), "team_search" (the group's DUO / SQUAD: Cloud.group_start) or "team_later" (online teams
## switched off); "duel" for SOLO in a group of exactly two (`group_n`: the group's players, 0 or 1
## for a solo): the 1 vs 1 between the two (start_duel).
static func start_route(m: String, size: int, teams_online := Game.TEAMS_ONLINE, group_n := 0) -> String:
	if m == "lonewolf":
		if size <= 1:
			return "duel" if group_n == 2 else "quick"
		return "team_search" if teams_online else "team_later"
	return "training_team" if size > 1 else "training"


## The match on this phone loads now (Game.team_match set by the caller: {} for the 1 vs 1).
func load_match() -> void:
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
	return _modal != null or dialogs.size_box != null or _find_settings() != null or profile_ui.layer != null


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
			# a full turn in about one screen width of drag, any way round (360 degrees)
			model.rotation.y = wrapf(model.rotation.y + d.relative.x / maxf(vs.x, 1.0) * 6.0, -PI, PI)
			hero_yaw = model.rotation.y
			_idle_t = 0.0


## Where a drag turns the character: around it, clear of the bars and the mode card.
func _in_drag_zone(p: Vector2) -> bool:
	var vs := get_viewport().get_visible_rect().size
	var x := p.x / vs.x
	var y := p.y / vs.y
	if wardrobe:
		return x > 0.62 and y > 0.1 and y < 0.68
	return x > HERO_X - 0.22 and x < HERO_X + 0.16 and y > 0.1 and y < 0.86


func _process(delta: float) -> void:
	_time += delta
	_idle_t += delta
	friends.process(delta)
	_chat_t -= delta
	if _chat_t <= 0.0:
		_chat_t = 0.5
		_refresh_chat_strip()
	if _cam_t < 1.0:
		_cam_t = minf(1.0, _cam_t + delta / 0.45)
		var k := 1.0 - pow(1.0 - _cam_t, 3.0)
		camera.position = _cam_from_pos.lerp(_cam_to_pos, k)
		camera.look_at(_cam_from_look.lerp(_cam_to_look, k))
	if start_btn and not start_btn.disabled:
		var s := 1.0 + sin(_time * 3.2) * 0.012
		start_btn.pivot_offset = start_btn.size * 0.5
		start_btn.scale = Vector2(s, s)
	if start_btn:
		start_btn.queue_redraw()
	wardrobe_ui.process()
	profile_ui.process(delta)
	team.process(delta)
	_follow_search(delta)
	if group_view:
		group_view.visible = wardrobe == null      # the wardrobe's view is the hero's alone
	_follow_podium_invite()
	_gate_t -= delta
	if _gate_t <= 0.0:
		_gate_t = 0.25
		update_start_gate()


## Android back: closes the top-most layer (settings, the team-size box, a popup: its own way
## back, PROFILE, the wardrobe); with nothing open it cancels a running search (the search tab's X), else asks before
## quitting; while START's match loading runs it does nothing.
func _notification(what: int) -> void:
	if what != NOTIFICATION_WM_GO_BACK_REQUEST:
		return
	if start_btn and start_btn.disabled:
		return                      # the match is loading
	var sp := _find_settings()
	if sp and not sp.covered():
		return                      # the panel closes itself
	if _modal:                      # (also a popup that came in over the settings panel or the size box)
		dialogs.back()
	elif dialogs.size_box:
		dialogs.close_size_box()
	elif profile_ui.layer:
		profile_ui.close()
	elif wardrobe:
		model.apply_bundle(String(Game.profile.bundle))
		_close_wardrobe()
	elif search_kind() != "" and search_tab.on_cancel.is_valid():
		cancel_search()             # with no window open, back cancels the search (not a member's)
	else:
		dialogs.confirm_quit()
