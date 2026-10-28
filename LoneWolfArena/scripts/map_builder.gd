class_name MapBuilder
extends RefCounted
## "CARGO CAGE": an original indoor warehouse duel arena (42 x 30 m hall, 9 m corrugated walls,
## pitched roof on steel trusses with hanging fluorescent tubes). Spawn alcoves sit in the middle
## of both short walls; the layout has 180-degree rotational symmetry (every piece of the west
## half is repeated rotated about the hall centre), so both spawns are equally fair.
## Gameplay pieces: a central high-ground block of two 40 ft containers (steel ramps + crate
## steps), long containers along the long walls, a walk-through container per side, a 2-high
## stack and a tilted container per side, crates, barrels, pallets, a forklift / a tank.
## Rendering: repeated meshes are MultiMeshes (per-instance container colours), static pieces are
## merged per material (see map_kit.gd); roof, ceiling, trusses and lamps live on visual layer 2
## so the top-down minimap camera (cull mask 1) sees the floor plan.

const Kit := preload("res://scripts/map_kit.gd")

const HX := 21.0                 # half length of the hall interior (x)
const HZ := 15.0                 # half width (z)
const WALL_H := 9.0
const BAY := 6.0
const AL_D := 6.0                # spawn alcove depth beyond the short walls
const AL_HW := 3.0               # alcove half width
const AL_H := 4.6                # alcove ceiling
const EAVE_Y := 9.62             # roof underside at the long walls
const RIDGE_Y := 11.08           # roof underside at the ridge (z = 0)
const C_H := 2.591
const C20 := Vector3(6.058, 2.591, 2.438)
const C40 := Vector3(12.192, 2.591, 2.438)
const CRATE := 1.2
const LAYER_ROOF := 2
const LAYER_FX := 4              # same bit as CharacterModel.LAYER_ACTORS (not in the minimap)
## Corrugated walls, columns and lintels: excluded from the sun's cull mask (soft ambient only,
## no harsh grazing-light stripes on the real corrugation) and from the minimap camera.
const LAYER_WALLS := 16
const TRUSS_X := [-15.0, -9.0, -3.0, 3.0, 9.0, 15.0]

const LIGHT_BLUE := Color("67b2e6")
const LIGHT_BLUE2 := Color("7dc3ec")
const DEEP_BLUE := Color("2c5aa6")
const RUST := Color("a63f2c")
const ORANGE := Color("e27a24")
const CREAM := Color("e4d5aa")
const TEAL := Color("3f8f8a")

var nav: NavigationRegion3D
var deco: Node3D
var env: WorldEnvironment
var sun: DirectionalLight3D
var obstacles: Array[Rect2] = []
var cover_points: Array[Vector3] = []
var spawn_a := Vector3(-HX - 2.0, 0, 0)
var spawn_b := Vector3(HX + 2.0, 0, 0)
var spawn_a_yaw := -PI * 0.5     # facing +X (into the hall)
var spawn_b_yaw := PI * 0.5      # facing -X
var map_name := "CARGO CAGE"
## Minimap area: the hall interior plus both spawn alcoves (and the wall caps around them).
var map_rect := Rect2(-HX - AL_D - 0.6, -HZ - 0.6, (HX + AL_D + 0.6) * 2.0, (HZ + 0.6) * 2.0)
var zone_center := Vector3.ZERO
var zone_start_radius := 27.6    # covers the hall corners (25.8 m) and the alcoves (27.2 m)

var kit = Kit.new()
var _S := Transform3D.IDENTITY   # current half: identity (west / A) or 180 degrees (east / B)
var _side := 0
var _barrier_vis: Array[Node3D] = []
var _barrier_shapes: Array[CollisionShape3D] = []
var _minor: Array[Node3D] = []
var _small: Array[GeometryInstance3D] = []
var _bay_cols := {}              # rounded column positions already placed


func build(parent: Node3D) -> void:
	nav = NavigationRegion3D.new()
	nav.name = "Navigation"
	parent.add_child(nav)
	var nm := NavigationMesh.new()
	nm.geometry_parsed_geometry_type = NavigationMesh.PARSED_GEOMETRY_STATIC_COLLIDERS
	nm.geometry_collision_mask = Fighter.LAYER_WORLD
	nm.agent_radius = 0.5
	nm.agent_height = 1.75
	nm.agent_max_climb = 0.25
	nm.agent_max_slope = 40.0
	# Unreachable islands (roofs of containers without a ramp, crate tops) are dropped so the bot
	# never picks a destination it cannot walk to.
	nm.region_min_size = 22.0
	nm.filter_low_hanging_obstacles = true
	# (no ledge filter: at 0.25 m cells it rejects every slope steeper than ~26 degrees)
	nm.filter_walkable_low_height_spans = true
	nm.filter_baking_aabb = AABB(Vector3(-HX - AL_D - 1.0, -1.0, -HZ - 1.0), Vector3((HX + AL_D + 1.0) * 2.0, 7.5, (HZ + 1.0) * 2.0))
	nav.navigation_mesh = nm
	deco = Node3D.new()
	deco.name = "Decor"
	parent.add_child(deco)
	_build_environment(parent)
	_configure_sets()
	_floor()
	_roof()
	for side in 2:
		_side = side
		_S = Transform3D.IDENTITY if side == 0 else Transform3D(Basis(Vector3.UP, PI), Vector3.ZERO)
		_shell_half()
		_layout_half()
	_S = Transform3D.IDENTITY
	_side = 0
	var batches: Dictionary = kit.build_batches(deco)
	var sets: Dictionary = kit.build_sets(deco)
	_collect_quality_groups(batches, sets)
	_make_cover_points()


# ---------------------------------------------------------------- environment / API

func _build_environment(parent: Node3D) -> void:
	env = WorldEnvironment.new()
	env.name = "Environment"
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.6, 0.62, 0.65)
	# Ambient from a neutral "indoor" sky: bright from above and the sides (windows, walls),
	# darker from below, so shapes read even where the sun does not reach.
	var sky := Sky.new()
	var sm := ProceduralSkyMaterial.new()
	sm.sky_top_color = Color(0.78, 0.8, 0.84)
	sm.sky_horizon_color = Color(0.8, 0.79, 0.76)
	sm.ground_horizon_color = Color(0.62, 0.6, 0.57)
	sm.ground_bottom_color = Color(0.5, 0.49, 0.47)
	sm.sun_angle_max = 0.0
	sky.sky_material = sm
	e.sky = sky
	e.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	e.ambient_light_sky_contribution = 1.0
	e.ambient_light_energy = 0.5
	e.reflected_light_source = Environment.REFLECTION_SOURCE_DISABLED
	e.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	e.tonemap_exposure = 1.0
	e.tonemap_white = 6.0
	e.adjustment_enabled = true
	e.adjustment_brightness = 1.0
	e.adjustment_contrast = 1.06
	e.adjustment_saturation = 1.18
	e.glow_enabled = true
	e.glow_intensity = 0.55
	e.glow_strength = 1.0
	e.glow_bloom = 0.0
	e.glow_hdr_threshold = 1.05
	e.glow_blend_mode = Environment.GLOW_BLEND_MODE_SOFTLIGHT
	env.environment = e
	parent.add_child(env)
	sun = DirectionalLight3D.new()
	sun.name = "Sun"
	# High, slightly warm daylight through the roof lights: crisp container / crate shadows.
	sun.rotation_degrees = Vector3(-66, -36, 0)
	sun.light_energy = 1.05
	sun.light_color = Color(1.0, 0.97, 0.92)
	sun.sky_mode = DirectionalLight3D.SKY_MODE_LIGHT_ONLY
	sun.light_cull_mask = 0xFFFFF & ~LAYER_WALLS
	sun.shadow_enabled = true
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS
	sun.directional_shadow_max_distance = 48.0
	sun.directional_shadow_split_1 = 0.3
	sun.shadow_bias = 0.04
	sun.shadow_normal_bias = 1.2
	sun.shadow_blur = 1.2
	parent.add_child(sun)


## Red spawn barriers during the prep phase: glowing wall + floor strip at both alcove mouths,
## red tint inside the alcoves, colliders only while on.
func set_barriers(on: bool) -> void:
	for n in _barrier_vis:
		if is_instance_valid(n):
			n.visible = on
	for cs in _barrier_shapes:
		if is_instance_valid(cs):
			cs.set_deferred("disabled", not on)


## Graphics quality 0..3 (SMOOTH..MAX): minor decoration hidden on SMOOTH, small props cast
## shadows on ULTRA / MAX only (containers, ramps and the high ground always do).
func apply_quality(g: int) -> void:
	for n in _minor:
		if is_instance_valid(n):
			n.visible = g >= 1
	for gi in _small:
		if is_instance_valid(gi):
			gi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if g >= 2 else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


func _collect_quality_groups(batches: Dictionary, sets: Dictionary) -> void:
	for key in ["signs", "roof_detail", "wall_detail"]:
		if batches.has(key):
			_minor.append(batches[key])
	for key in ["fire_cabinet", "lamps_alcove"]:
		if sets.has(key):
			for n in sets[key]:
				_minor.append(n)
	for key in ["crate", "barrel", "pallet", "bollard", "fire_cabinet", "forklift", "tank", "door"]:
		if sets.has(key):
			for n in sets[key]:
				_small.append(n)
	for key in ["props_small"]:
		if batches.has(key):
			_small.append(batches[key])
	for key in ["barrier", "barrier_fog"]:
		if batches.has(key):
			var mi: MeshInstance3D = batches[key]
			mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			_barrier_vis.append(mi)


# ---------------------------------------------------------------- placement helpers

## Transform in the current half (the west half is authored; the east half is rotated 180 deg).
func _xf(pos: Vector3, yaw_deg := 0.0) -> Transform3D:
	return _S * Transform3D(Basis(Vector3.UP, deg_to_rad(yaw_deg)), pos)


func _p(pos: Vector3) -> Vector3:
	return _S * pos


func _dir(v: Vector3) -> Vector3:
	return _S.basis * v


func _body(xf: Transform3D, size: Vector3, parent: Node = null) -> CollisionShape3D:
	var body := StaticBody3D.new()
	body.collision_layer = Fighter.LAYER_WORLD
	body.collision_mask = 0
	var cs := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = size
	cs.shape = bs
	body.add_child(cs)
	(parent if parent else nav).add_child(body)
	body.transform = xf
	return cs


## Box collider (centre transform, already in world space) on the world layer, parented under
## the navigation region so the navmesh bakes from it; footprint -> obstacles.
func _collider(size: Vector3, xf: Transform3D, footprint := true) -> void:
	_body(xf, size)
	if footprint:
		_footprint(size, xf)


func _footprint(size: Vector3, xf: Transform3D) -> void:
	# rotated boxes: the AABB of the rotated box corners on the floor plane
	var h := size * 0.5
	var mn := Vector2(INF, INF)
	var mx := Vector2(-INF, -INF)
	for sx in [-1.0, 1.0]:
		for sy in [-1.0, 1.0]:
			for sz in [-1.0, 1.0]:
				var c := xf * Vector3(h.x * sx, h.y * sy, h.z * sz)
				mn = Vector2(minf(mn.x, c.x), minf(mn.y, c.z))
				mx = Vector2(maxf(mx.x, c.x), maxf(mx.y, c.z))
	obstacles.append(Rect2(mn, mx - mn))


# ---------------------------------------------------------------- prop sets (MultiMeshes)

func _configure_sets() -> void:
	var cont := {"paint": "paint", "metal": "metal_dark", "rubber": "rubber", "wood": "wood_floor"}
	kit.set_config("c40", "container_40", cont, 1, 1, true)
	kit.set_fallback("c40", [["paint", C40, Vector3(0, C_H * 0.5, 0)]])
	kit.set_config("c20", "container", cont, 1, 1, true)
	kit.set_fallback("c20", [["paint", C20, Vector3(0, C_H * 0.5, 0)]])
	kit.set_config("copen", "container_open", cont, 1, 1, true)
	kit.set_fallback("copen", [["paint", Vector3(6.058, 0.12, 2.438), Vector3(0, 2.53, 0)],
		["paint", Vector3(6.058, 2.591, 0.07), Vector3(0, 1.3, -1.18)], ["paint", Vector3(6.058, 2.591, 0.07), Vector3(0, 1.3, 1.18)],
		["wood_floor", Vector3(6.0, 0.12, 2.3), Vector3(0, 0.06, 0)]])
	kit.set_config("crate", "crate", {"wooddark": "crate_dark", "wood": "crate"}, 1)
	kit.set_fallback("crate", [["crate", Vector3.ONE * CRATE, Vector3(0, CRATE * 0.5, 0)]])
	kit.set_config("bay", "wall_bay", {"walllower": "wall_lower", "wallupper": "wall_upper", "steel": "steel", "frame": "frame", "glass": "window"}, 0, LAYER_WALLS)
	kit.set_fallback("bay", [["wall_lower", Vector3(6.0, 2.6, 0.25), Vector3(0, 1.3, 0)], ["wall_upper", Vector3(6.0, 6.4, 0.25), Vector3(0, 5.8, 0)]])
	kit.set_config("column", "wall_column", {"steel": "steel"}, 0, LAYER_WALLS)
	kit.set_fallback("column", [["steel", Vector3(0.32, 9.0, 0.32), Vector3(0, 4.5, 0)]])
	kit.set_config("door", "rollup_door", {"shutter": "shutter", "steel": "steel", "yellow": "yellow", "black": "black"}, 1)
	kit.set_fallback("door", [["shutter", Vector3(4.4, 5.0, 0.12), Vector3(0, 2.5, -0.12)], ["steel", Vector3(5.0, 0.6, 0.45), Vector3(0, 5.3, -0.22)]])
	kit.set_config("truss", "roof_truss", {"truss": "truss"}, 0, LAYER_ROOF)
	kit.set_fallback("truss", [["truss", Vector3(30.0, 0.17, 0.17), Vector3(0, 0.085, 0)], ["truss", Vector3(30.0, 0.15, 0.15), Vector3(0, 1.2, 0)],
		["truss", Vector3(0.15, 2.0, 0.15), Vector3(0, 1.0, 0)]])
	kit.set_config("lamps", "lamp_tube", {"lamphousing": "lamp_housing", "steel": "steel", "lamp": "lamp"}, 0, LAYER_ROOF)
	kit.set_fallback("lamps", [["steel", Vector3(0.02, 1.12, 0.02), Vector3(-0.55, -0.56, 0)], ["steel", Vector3(0.02, 1.12, 0.02), Vector3(0.55, -0.56, 0)],
		["lamp_housing", Vector3(1.4, 0.08, 0.26), Vector3(0, -1.16, 0)], ["lamp", Vector3(1.32, 0.04, 0.16), Vector3(0, -1.215, 0)]])
	kit.set_config("barrel", "barrel", {"paint": "barrel_paint", "metal": "metal"}, 1, 1, true)
	kit.set_fallback("barrel", [["barrel_paint", Vector3(0.585, 0.88, 0.585), Vector3(0, 0.44, 0)]])
	kit.set_config("pallet", "pallet", {"wooddark": "pallet_dark", "wood": "pallet"}, 1)
	kit.set_fallback("pallet", [["pallet", Vector3(1.2, 0.144, 0.8), Vector3(0, 0.072, 0)]])
	kit.set_config("bollard", "bollard", {"yellow": "yellow", "black": "black"}, 1)
	kit.set_fallback("bollard", [["yellow", Vector3(0.16, 1.1, 0.16), Vector3(0, 0.55, 0)]])
	kit.set_config("fire_cabinet", "fire_cabinet", {"redpaint": "red_paint", "glass": "glass_small", "metal": "metal", "black": "black"}, 1)
	kit.set_fallback("fire_cabinet", [["red_paint", Vector3(0.75, 0.95, 0.22), Vector3(0, 1.375, -0.11)], ["red_paint", Vector3(0.17, 0.5, 0.17), Vector3(0.58, 0.25, -0.14)]])
	kit.set_config("forklift", "forklift", {"paint": "fork_body", "body": "fork_body", "yellow": "fork_body", "metal": "metal_dark",
		"steel": "metal_dark", "rubber": "rubber", "tire": "rubber", "black": "black", "glass": "glass_small", "seat": "black"}, 1)
	kit.set_fallback("forklift", [
		["fork_body", Vector3(1.15, 0.55, 2.0), Vector3(0, 0.55, 0.15)], ["fork_body", Vector3(1.15, 0.75, 0.55), Vector3(0, 0.95, 0.95)],
		["fork_body", "cyl", 0.3, 1.15, Vector3(0, 1.32, 1.0), "x"],
		["black", Vector3(0.5, 0.14, 0.5), Vector3(0, 1.2, 0.35)], ["black", Vector3(0.5, 0.5, 0.1), Vector3(0, 1.5, 0.62)],
		["black", Vector3(0.07, 1.3, 0.07), Vector3(-0.52, 1.5, -0.35)], ["black", Vector3(0.07, 1.3, 0.07), Vector3(0.52, 1.5, -0.35)],
		["black", Vector3(0.07, 1.0, 0.07), Vector3(-0.52, 1.65, 0.78)], ["black", Vector3(0.07, 1.0, 0.07), Vector3(0.52, 1.65, 0.78)],
		["black", Vector3(1.12, 0.06, 1.25), Vector3(0, 2.17, 0.22)], ["black", "cyl", 0.17, 0.04, Vector3(0, 1.48, -0.12), "y"],
		["metal_dark", Vector3(0.1, 2.3, 0.12), Vector3(-0.36, 1.18, -1.0)], ["metal_dark", Vector3(0.1, 2.3, 0.12), Vector3(0.36, 1.18, -1.0)],
		["metal_dark", Vector3(0.82, 0.08, 0.1), Vector3(0, 2.25, -1.0)], ["metal_dark", Vector3(0.9, 0.42, 0.08), Vector3(0, 0.45, -1.1)],
		["metal_dark", Vector3(0.12, 0.05, 1.1), Vector3(-0.25, 0.08, -1.65)], ["metal_dark", Vector3(0.12, 0.05, 1.1), Vector3(0.25, 0.08, -1.65)],
		["rubber", "cyl", 0.3, 0.24, Vector3(-0.5, 0.3, -0.6), "x"], ["rubber", "cyl", 0.3, 0.24, Vector3(0.5, 0.3, -0.6), "x"],
		["rubber", "cyl", 0.25, 0.22, Vector3(-0.5, 0.25, 0.8), "x"], ["rubber", "cyl", 0.25, 0.22, Vector3(0.5, 0.25, 0.8), "x"],
		["yellow", "cyl", 0.06, 0.1, Vector3(0, 2.25, 0.7), "y"]])
	kit.set_config("tank", "tank", {"tank": "tank", "body": "tank", "paint": "tank", "metal": "metal_dark", "steel": "metal_dark", "frame": "metal_dark",
		"yellow": "yellow", "black": "black", "red": "red_paint"}, 1)
	kit.set_fallback("tank", [
		["tank", "cyl", 0.85, 2.7, Vector3(0, 1.3, 0), "x"], ["tank", "sph", 0.85, Vector3(-1.35, 1.3, 0), Vector3(0.42, 1, 1)],
		["tank", "sph", 0.85, Vector3(1.35, 1.3, 0), Vector3(0.42, 1, 1)], ["metal_dark", "cyl", 0.87, 0.08, Vector3(-0.7, 1.3, 0), "x"],
		["metal_dark", "cyl", 0.87, 0.08, Vector3(0.7, 1.3, 0), "x"],
		["metal_dark", Vector3(0.3, 0.55, 1.4), Vector3(-0.9, 0.27, 0)], ["metal_dark", Vector3(0.3, 0.55, 1.4), Vector3(0.9, 0.27, 0)],
		["tank", "cyl", 0.24, 0.3, Vector3(0.3, 2.18, 0), "y"], ["metal_dark", "cyl", 0.27, 0.05, Vector3(0.3, 2.33, 0), "y"],
		["yellow", "cyl", 0.06, 0.9, Vector3(-1.1, 0.45, 0.55), "y"], ["red_paint", "cyl", 0.11, 0.06, Vector3(-1.1, 0.9, 0.55), "y"],
		["metal_dark", Vector3(0.05, 2.2, 0.05), Vector3(1.75, 1.1, -0.22)], ["metal_dark", Vector3(0.05, 2.2, 0.05), Vector3(1.75, 1.1, 0.22)],
		["metal_dark", Vector3(0.04, 0.04, 0.44), Vector3(1.75, 0.5, 0)], ["metal_dark", Vector3(0.04, 0.04, 0.44), Vector3(1.75, 0.9, 0)],
		["metal_dark", Vector3(0.04, 0.04, 0.44), Vector3(1.75, 1.3, 0)], ["metal_dark", Vector3(0.04, 0.04, 0.44), Vector3(1.75, 1.7, 0)],
		["yellow", Vector3(0.6, 0.04, 0.03), Vector3(0.0, 1.3, 0.86)]])


# ---------------------------------------------------------------- floor

func _floor() -> void:
	kit.batch_config("floor", 1, false)
	# hall + both alcoves (slab joints every 4 m, centred on the hall)
	for r in [Rect2(-HX - 0.3, -HZ - 0.3, HX * 2.0 + 0.6, HZ * 2.0 + 0.6), Rect2(-HX - AL_D - 0.3, -AL_HW - 0.3, AL_D + 0.1, AL_HW * 2.0 + 0.6),
			Rect2(HX + 0.2, -AL_HW - 0.3, AL_D + 0.1, AL_HW * 2.0 + 0.6)]:
		var pts := [Vector3(r.position.x, 0, r.position.y), Vector3(r.end.x, 0, r.position.y), Vector3(r.end.x, 0, r.end.y), Vector3(r.position.x, 0, r.end.y)]
		var uvs := []
		for q: Vector3 in pts:
			uvs.append(Vector2(q.x, q.z) / 4.0 + Vector2(0.5, 0.5))
		kit.quad("floor", "floor", pts, uvs, Vector3.UP)
	# dark ground around the building: only the top-down minimap camera ever sees it
	var g := 70.0
	kit.quad("floor", "void", [Vector3(-g, -0.06, -g), Vector3(g, -0.06, -g), Vector3(g, -0.06, g), Vector3(-g, -0.06, g)],
		[Vector2.ZERO, Vector2.ONE, Vector2.ONE, Vector2.ZERO], Vector3.UP)
	# floor colliders only inside the building (no navmesh outside the walls)
	_collider(Vector3(HX * 2.0 + 1.4, 2.0, HZ * 2.0 + 1.4), Transform3D(Basis.IDENTITY, Vector3(0, -1, 0)), false)
	for sx in [-1.0, 1.0]:
		_collider(Vector3(AL_D + 0.8, 2.0, AL_HW * 2.0 + 1.4), Transform3D(Basis.IDENTITY, Vector3(sx * (HX + AL_D * 0.5), -1, 0)), false)


## Flat floor decal (hatched pad, hazard strip, painted line) in the current half.
## rect corners in authored (west-half) coordinates; uv_per_m: texture repeats per metre.
func _decal(mat_key: String, c: Vector3, size: Vector2, yaw_deg: float, uv_scale: Vector2, y := 0.012) -> void:
	var b := Basis(Vector3.UP, deg_to_rad(yaw_deg))
	var hx := size.x * 0.5
	var hz := size.y * 0.5
	var loc := [Vector3(-hx, 0, -hz), Vector3(hx, 0, -hz), Vector3(hx, 0, hz), Vector3(-hx, 0, hz)]
	var pts := []
	for q: Vector3 in loc:
		pts.append(_p(c + b * q + Vector3(0, y, 0)))
	var uvs := [Vector2(0, 0), Vector2(size.x * uv_scale.x, 0), Vector2(size.x * uv_scale.x, size.y * uv_scale.y), Vector2(0, size.y * uv_scale.y)]
	kit.quad("floor", mat_key, pts, uvs, Vector3.UP)


func _hatch_pad(c: Vector3, size: Vector2) -> void:
	# the hatch texture is one framed pad: stretch it over the whole rectangle
	var b := Basis.IDENTITY
	var hx := size.x * 0.5
	var hz := size.y * 0.5
	var loc := [Vector3(-hx, 0, -hz), Vector3(hx, 0, -hz), Vector3(hx, 0, hz), Vector3(-hx, 0, hz)]
	var pts := []
	for q: Vector3 in loc:
		pts.append(_p(c + b * q + Vector3(0, 0.01, 0)))
	kit.quad("floor", "hatch", pts, [Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)], Vector3.UP)


func _hazard_strip(a: Vector3, b: Vector3, width := 0.45) -> void:
	var d := b - a
	var length := d.length()
	var yaw := rad_to_deg(atan2(-d.z, d.x))
	_decal("hazard", (a + b) * 0.5, Vector2(length, width), yaw, Vector2.ONE, 0.014)


func _dashed_line(a: Vector3, b: Vector3, dash := 1.0, gap := 0.7, width := 0.12) -> void:
	var d := b - a
	var length := d.length()
	var dir := d / length
	var yaw := rad_to_deg(atan2(-dir.z, dir.x))
	var t := 0.0
	while t < length - 0.05:
		var e := minf(t + dash, length)
		_decal("line_paint", a + dir * ((t + e) * 0.5), Vector2(e - t, width), yaw, Vector2.ONE, 0.011)
		t = e + gap


## Soft contact shadow around a rectangular footprint (authored coords, yaw in degrees): a
## 9-slice of the contact-shadow cell of floor_decals.png, margin m wide, strength 0..1.
func _ao(c: Vector3, size: Vector2, yaw_deg: float, m := 0.55, strength := 0.75) -> void:
	var b := Basis(Vector3.UP, deg_to_rad(yaw_deg))
	var xs := [-size.x * 0.5 - m, -size.x * 0.5, size.x * 0.5, size.x * 0.5 + m]
	var zs := [-size.y * 0.5 - m, -size.y * 0.5, size.y * 0.5, size.y * 0.5 + m]
	var us := [0.0, 0.25, 0.25, 0.5]
	var col := Color(1, 1, 1, strength)
	for i in 3:
		for j in 3:
			if i == 1 and j == 1:
				continue           # under the object: never visible
			var pts := []
			var uvs := []
			for k in [[i, j], [i + 1, j], [i + 1, j + 1], [i, j + 1]]:
				pts.append(_p(c + b * Vector3(xs[k[0]], 0, zs[k[1]]) + Vector3(0, 0.007, 0)))
				uvs.append(Vector2(us[k[0]], us[k[1]]))
			kit.quad("floor", "decals", pts, uvs, Vector3.UP, col)


## Darkening strip along a wall base: a/b on the wall line, n = inward normal (authored coords).
func _ao_strip(a: Vector3, b: Vector3, n: Vector3, width := 0.8, strength := 0.55) -> void:
	var y := Vector3(0, 0.006, 0)
	var pts := [_p(a + y), _p(b + y), _p(b + n * width + y), _p(a + n * width + y)]
	kit.quad("floor", "decals", pts, [Vector2(0.25, 0.25), Vector2(0.25, 0.25), Vector2(0.0, 0.25), Vector2(0.0, 0.25)], Vector3.UP, Color(1, 1, 1, strength))


## Floor overlay from the decal atlas: cell 1 oil stain, 2 grime, 3 tyre marks.
func _stain(cell: int, c: Vector3, size: Vector2, yaw_deg: float, strength := 1.0) -> void:
	var b := Basis(Vector3.UP, deg_to_rad(yaw_deg))
	var u0 := (cell % 2) * 0.5
	var v0 := (cell / 2) * 0.5
	var hx := size.x * 0.5
	var hz := size.y * 0.5
	var pts := []
	for q in [Vector3(-hx, 0, -hz), Vector3(hx, 0, -hz), Vector3(hx, 0, hz), Vector3(-hx, 0, hz)]:
		pts.append(_p(c + b * q + Vector3(0, 0.008, 0)))
	var uvs := [Vector2(u0, v0), Vector2(u0 + 0.5, v0), Vector2(u0 + 0.5, v0 + 0.5), Vector2(u0, v0 + 0.5)]
	kit.quad("floor", "decals", pts, uvs, Vector3.UP, Color(1, 1, 1, strength))


# ---------------------------------------------------------------- hall shell (per half)

## One wall run along a straight line: bays (MultiMesh), a collider, a white top cap for the
## minimap. a/b are the run ends ON the inner wall line, n = inward normal (all authored coords).
func _wall_run(a: Vector3, b: Vector3, n: Vector3, bays := true) -> void:
	var length := a.distance_to(b)
	var along := (b - a) / length
	var wa := _p(a)
	var wb := _p(b)
	var wn := _dir(n)
	var wal := _dir(along)
	var yaw := atan2(-wn.x, -wn.z)       # bay front (-Z) faces the hall
	var basis := Basis(Vector3.UP, yaw)
	if bays:
		var nb := int(round(length / BAY))
		for i in nb:
			var c := wa + wal * (BAY * (i + 0.5)) - wn * 0.045
			kit.add("bay", Transform3D(basis, c))
	# collider: inner face 0.08 in front of the cladding crests, 0.7 thick
	var mid := (wa + wb) * 0.5 + wn * (0.08 - 0.35) + Vector3(0, WALL_H * 0.5, 0)
	var cb := Basis(Vector3.UP, yaw)
	_collider(Vector3(length + 0.1, WALL_H, 0.7), Transform3D(cb, mid), false)
	# soft darkening of the floor along the wall base
	_ao_strip(a, b, n, 0.9, 0.5)
	# white cap on top of the wall: the minimap's outline
	kit.batch_config("caps", 1, false)
	kit.box("caps", "white_cap", Vector3(length + 0.5, 0.06, 0.5), Transform3D(cb, (wa + wb) * 0.5 - wn * 0.06 + Vector3(0, WALL_H + 0.03, 0)), 1.0, ["-x", "+x", "-z", "+z", "-y"])


func _column(pos: Vector3, yaw_deg: float) -> void:
	var w := _p(pos)
	var key := "%d_%d" % [roundi(w.x * 10.0), roundi(w.z * 10.0)]
	if _bay_cols.has(key):
		return
	_bay_cols[key] = true
	var xf := _xf(pos, yaw_deg)
	kit.add("column", xf)
	_collider(Vector3(0.4, WALL_H, 0.42), Transform3D(xf.basis, xf.origin + Vector3(0, WALL_H * 0.5, 0)), false)


func _shell_half() -> void:
	# The west half authors the whole north wall (the 180-degree copy becomes the south wall)
	# and the west short wall with its alcove (the copy becomes the east wall + alcove B).
	_wall_run(Vector3(-HX, 0, -HZ), Vector3(HX, 0, -HZ), Vector3(0, 0, 1))
	# short wall (west) with the alcove opening in the middle bay
	_wall_run(Vector3(-HX, 0, -HZ), Vector3(-HX, 0, -AL_HW), Vector3(1, 0, 0))
	_wall_run(Vector3(-HX, 0, AL_HW), Vector3(-HX, 0, HZ), Vector3(1, 0, 0))
	# spawn alcove: back + two sides
	_wall_run(Vector3(-HX - AL_D, 0, -AL_HW), Vector3(-HX - AL_D, 0, AL_HW), Vector3(1, 0, 0))
	_wall_run(Vector3(-HX - AL_D, 0, -AL_HW), Vector3(-HX, 0, -AL_HW), Vector3(0, 0, 1))
	_wall_run(Vector3(-HX - AL_D, 0, AL_HW), Vector3(-HX, 0, AL_HW), Vector3(0, 0, -1))
	# columns at the bay joints (in front of the wall, flanges toward the hall)
	var off := 0.24
	for i in 8:
		var x := -HX + BAY * i
		x += off if i == 0 else (-off if i == 7 else 0.0)
		_column(Vector3(x, 0, -HZ + off), 180.0)
	for z in [-HZ + BAY, -AL_HW - off, AL_HW + off, HZ - BAY]:
		_column(Vector3(-HX + off, 0, z), -90.0)
	_column(Vector3(-HX - AL_D + off, 0, -AL_HW + off), -90.0)
	_column(Vector3(-HX - AL_D + off, 0, AL_HW - off), -90.0)
	# lintel above the alcove mouth + hazard-striped header beam + alcove ceiling (layer 2)
	kit.batch_config("shell", LAYER_WALLS, false)
	var lintel := Vector3(0.25, WALL_H - AL_H, AL_HW * 2.0 + 0.5)
	kit.box("shell", "header", lintel, _xf(Vector3(-HX - 0.08, AL_H + lintel.y * 0.5, 0)), 1.0, ["-x"])
	kit.box("shell", "hazard", Vector3(0.36, 0.32, AL_HW * 2.0 + 0.4), _xf(Vector3(-HX + 0.06, AL_H - 0.12, 0)), 1.0)
	kit.batch_config("ceiling", LAYER_ROOF, false)
	kit.box("ceiling", "roof", Vector3(AL_D + 0.2, 0.15, AL_HW * 2.0 + 0.3), _xf(Vector3(-HX - AL_D * 0.5, AL_H + 0.075, 0)), 0.5)
	# flush ceiling lights in the alcove
	for z in [-1.4, 1.4]:
		kit.box("ceiling", "lamp_housing", Vector3(1.5, 0.06, 0.3), _xf(Vector3(-HX - AL_D * 0.5, AL_H - 0.03, z)), 1.0, ["+y"])
		kit.box("ceiling", "lamp", Vector3(1.36, 0.03, 0.18), _xf(Vector3(-HX - AL_D * 0.5, AL_H - 0.065, z)), 1.0, ["+y"])
	_collider(Vector3(AL_D + 0.4, 0.3, AL_HW * 2.0 + 0.4), _xf(Vector3(-HX - AL_D * 0.5, AL_H + 0.15, 0)), false)
	_collider(Vector3(0.4, WALL_H - AL_H, AL_HW * 2.0 + 0.4), _xf(Vector3(-HX - 0.1, AL_H + (WALL_H - AL_H) * 0.5, 0)), false)
	# spawn barrier (prep phase): glowing wall + floor strip at the mouth, red tint inside
	_barrier_half()
	# roll-up door on the north wall, fire cabinets
	_wall_prop("door", Vector3(-6.0, 0, -HZ), Vector3(0, 0, 1))
	_collider(Vector3(5.0, 5.6, 0.5), _xf(Vector3(-6.0, 2.8, -HZ + 0.25)), false)
	_wall_prop("fire_cabinet", Vector3(-HX, 0, -7.4), Vector3(1, 0, 0))
	_collider(Vector3(0.3, 1.0, 0.8), _xf(Vector3(-HX + 0.15, 1.38, -7.4)), false)
	_wall_prop("fire_cabinet", Vector3(-12.9, 0, -HZ), Vector3(0, 0, 1))
	_collider(Vector3(0.8, 1.0, 0.3), _xf(Vector3(-12.9, 1.38, -HZ + 0.15)), false)
	_wall_details()
	# signs: area letter over the alcove, SAFE inside, chevrons toward the exit
	_sign(0 if _side == 0 else 1, Vector3(-HX + 0.1, 6.7, 0), Vector3(1, 0, 0), 2.0)
	_sign(7, Vector3(-HX - AL_D + 0.08, 3.0, 0), Vector3(1, 0, 0), 1.5)
	_sign(6, Vector3(-HX - 1.6, 1.45, -AL_HW + 0.08), Vector3(0, 0, 1), 0.75)
	_sign(6, Vector3(-HX - 1.6, 1.45, AL_HW - 0.08), Vector3(0, 0, -1), 0.75, true)
	_sign(2 if _side == 0 else 3, Vector3(-12.0, 4.1, -HZ + 0.1), Vector3(0, 0, 1), 1.5)
	_sign(4, Vector3(-HX + 0.1, 2.0, 9.0 - 1.0), Vector3(1, 0, 0), 0.9)


## Pipes, conduits, electrical boxes and lamps on the walls (visual only).
func _wall_details() -> void:
	kit.batch_config("wall_detail", 1, false)
	var pipe := CylinderMesh.new()
	pipe.top_radius = 0.07
	pipe.bottom_radius = 0.07
	pipe.height = HX * 2.0
	pipe.radial_segments = 8
	pipe.rings = 1
	pipe.cap_top = false
	pipe.cap_bottom = false
	# red sprinkler main under the eave of the north wall (+ hangers)
	kit.prim("wall_detail", "pipe_red", pipe, _S * Transform3D(Basis(Vector3.BACK, PI * 0.5), Vector3(0, 8.3, -HZ + 0.34)))
	for i in 15:
		var x := -HX + 1.5 + i * 3.0
		kit.box("wall_detail", "steel", Vector3(0.05, 0.3, 0.3), _S * Transform3D(Basis.IDENTITY, Vector3(x, 8.45, -HZ + 0.2)))
	# grey conduit above the girt on the short wall, a box beside the alcove and its feed
	var con := CylinderMesh.new()
	con.top_radius = 0.035
	con.bottom_radius = 0.035
	con.height = HZ - AL_HW - 0.6
	con.radial_segments = 6
	con.rings = 1
	for zs in [-1.0, 1.0]:
		var zc: float = zs * (AL_HW + 0.3 + con.height * 0.5)
		kit.prim("wall_detail", "conduit", con, _S * Transform3D(Basis(Vector3.RIGHT, PI * 0.5), Vector3(-HX + 0.16, 3.05, zc)))
	kit.box("wall_detail", "elec_box", Vector3(0.24, 0.85, 0.62), _xf(Vector3(-HX + 0.14, 1.55, -4.9)))
	kit.box("wall_detail", "frame", Vector3(0.05, 0.12, 0.5), _xf(Vector3(-HX + 0.27, 1.75, -4.9)))
	var feed := CylinderMesh.new()
	feed.top_radius = 0.03
	feed.bottom_radius = 0.03
	feed.height = 1.12
	feed.radial_segments = 6
	feed.rings = 1
	kit.prim("wall_detail", "conduit", feed, _S * Transform3D(Basis.IDENTITY, Vector3(-HX + 0.14, 2.5, -4.9)))
	kit.box("wall_detail", "elec_box", Vector3(0.5, 0.7, 0.22), _xf(Vector3(-2.35, 1.6, -HZ + 0.13)))
	# warm wall lamps on the lintel of the spawn door
	for z in [-2.3, 2.3]:
		kit.box("wall_detail", "frame", Vector3(0.14, 0.2, 0.44), _xf(Vector3(-HX + 0.03, 5.25, z)))
		kit.box("wall_detail", "lamp_warm", Vector3(0.03, 0.13, 0.36), _xf(Vector3(-HX + 0.11, 5.25, z)))


## Wall-mounted prop (door / fire cabinet): origin on the wall line, front toward the hall.
func _wall_prop(set_name: String, pos: Vector3, n: Vector3) -> void:
	var wn := _dir(n)
	var yaw := atan2(-wn.x, -wn.z)
	kit.add(set_name, Transform3D(Basis(Vector3.UP, yaw), _p(pos)))


## Sign from the 4x2 atlas (0 A, 1 B, 2 "1", 3 "2", 4 warning, 5 arrow, 6 chevrons, 7 SAFE)
## on a wall: centre c, facing n, size in metres. flip mirrors it horizontally.
func _sign(cell: int, c: Vector3, n: Vector3, size: float, flip := false) -> void:
	kit.batch_config("signs", 1, false)
	var wn := _dir(n).normalized()
	var right := Vector3.UP.cross(wn).normalized()   # viewer's right when facing the sign
	var wc := _p(c)
	var hs := size * 0.5
	var u0 := (cell % 4) * 0.25
	var v0 := (cell / 4) * 0.5
	var ul := u0 + (0.25 if flip else 0.0)
	var ur := u0 + (0.0 if flip else 0.25)
	var pts := [wc - right * hs + Vector3.UP * hs, wc + right * hs + Vector3.UP * hs, wc + right * hs - Vector3.UP * hs, wc - right * hs - Vector3.UP * hs]
	var uvs := [Vector2(ul, v0), Vector2(ur, v0), Vector2(ur, v0 + 0.5), Vector2(ul, v0 + 0.5)]
	kit.quad("signs", "signs", pts, uvs, wn)


func _floor_sign(cell: int, c: Vector3, size: float, yaw_deg: float) -> void:
	kit.batch_config("signs", 1, false)
	var b := _S.basis * Basis(Vector3.UP, deg_to_rad(yaw_deg))
	var wc := _p(c) + Vector3(0, 0.013, 0)
	var hs := size * 0.5
	var u0 := (cell % 4) * 0.25
	var v0 := (cell / 4) * 0.5
	var pts := [wc + b * Vector3(-hs, 0, -hs), wc + b * Vector3(hs, 0, -hs), wc + b * Vector3(hs, 0, hs), wc + b * Vector3(-hs, 0, hs)]
	var uvs := [Vector2(u0, v0), Vector2(u0 + 0.25, v0), Vector2(u0 + 0.25, v0 + 0.5), Vector2(u0, v0 + 0.5)]
	kit.quad("signs", "signs", pts, uvs, Vector3.UP)


func _barrier_half() -> void:
	kit.batch_config("barrier", LAYER_FX, false)
	var x := -HX + 0.02
	var h := AL_H - 0.3
	var pts := [_p(Vector3(x, 0, -AL_HW)), _p(Vector3(x, 0, AL_HW)), _p(Vector3(x, h, AL_HW)), _p(Vector3(x, h, -AL_HW))]
	kit.quad("barrier", "barrier", pts, [Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)], _dir(Vector3(1, 0, 0)))
	var s0 := [_p(Vector3(x - 0.25, 0.02, -AL_HW)), _p(Vector3(x - 0.25, 0.02, AL_HW)), _p(Vector3(x + 0.25, 0.02, AL_HW)), _p(Vector3(x + 0.25, 0.02, -AL_HW))]
	kit.quad("barrier", "barrier_floor", s0, [Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)], Vector3.UP)
	# red tint volume filling the alcove (inside faces seen from the spawn)
	kit.batch_config("barrier_fog", LAYER_FX, false)
	kit.box("barrier_fog", "barrier_fog", Vector3(AL_D - 0.1, AL_H - 0.1, AL_HW * 2.0 - 0.1), _xf(Vector3(-HX - AL_D * 0.5 - 0.02, AL_H * 0.5, 0)))
	# collider (not under the navigation region: the navmesh is baked with the mouth open)
	var cs := _body(_xf(Vector3(-HX + 0.1, AL_H * 0.5, 0)), Vector3(0.3, AL_H, AL_HW * 2.0), deco)
	cs.disabled = true
	_barrier_shapes.append(cs)


# ---------------------------------------------------------------- roof (both halves at once)

func _roof_y(z: float) -> float:
	return RIDGE_Y - (absf(z) / HZ) * (RIDGE_Y - EAVE_Y)


func _roof() -> void:
	kit.batch_config("roof", LAYER_ROOF, false)
	var xa := -HX - 0.3
	var xb := HX + 0.3
	for s in [-1.0, 1.0]:
		var ze: float = s * (HZ + 0.3)
		var ye := _roof_y(HZ + 0.3)
		var pts := [Vector3(xa, ye, ze), Vector3(xb, ye, ze), Vector3(xb, RIDGE_Y, 0), Vector3(xa, RIDGE_Y, 0)]
		var slope := Vector3(0, RIDGE_Y - ye, -ze).normalized()
		var n := Vector3(1, 0, 0).cross(slope).normalized()
		if n.y > 0.0:
			n = -n
		var sl := Vector2(0, ze).distance_to(Vector2(0, 0))
		kit.quad("roof", "roof", pts, [Vector2(xa * 0.5, sl * 0.5), Vector2(xb * 0.5, sl * 0.5), Vector2(xb * 0.5, 0), Vector2(xa * 0.5, 0)], n)
		# filler between the wall top and the eave along the long walls
		var zf: float = s * (HZ - 0.02)
		var fp := [Vector3(-HX, WALL_H - 0.05, zf), Vector3(HX, WALL_H - 0.05, zf), Vector3(HX, EAVE_Y + 0.05, zf), Vector3(-HX, EAVE_Y + 0.05, zf)]
		var v0 := RIDGE_Y - WALL_H + 0.05
		var v1 := RIDGE_Y - EAVE_Y - 0.05
		kit.quad("roof", "header", fp, [Vector2(-HX, v0), Vector2(HX, v0), Vector2(HX, v1), Vector2(-HX, v1)], Vector3(0, 0, -s))
	# gables above the short walls
	for s in [-1.0, 1.0]:
		var xg: float = s * (HX - 0.02)
		var n := Vector3(-s, 0, 0)
		var r := [Vector3(xg, WALL_H - 0.05, -HZ), Vector3(xg, WALL_H - 0.05, HZ), Vector3(xg, EAVE_Y, HZ), Vector3(xg, EAVE_Y, -HZ)]
		var va := RIDGE_Y - WALL_H + 0.05
		var vb := RIDGE_Y - EAVE_Y
		kit.quad("roof", "header", r, [Vector2(-HZ, va), Vector2(HZ, va), Vector2(HZ, vb), Vector2(-HZ, vb)], n)
		kit.tri("roof", "header", [Vector3(xg, EAVE_Y, -HZ), Vector3(xg, EAVE_Y, HZ), Vector3(xg, RIDGE_Y + 0.05, 0)],
			[Vector2(-HZ, vb), Vector2(HZ, vb), Vector2(0, 0)], n)
	# trusses on the column lines, purlins and a ridge beam
	for x: float in TRUSS_X:
		kit.add("truss", Transform3D(Basis(Vector3.UP, PI * 0.5), Vector3(x, WALL_H, 0)))
	kit.batch_config("roof_detail", LAYER_ROOF, false)
	for z in [-13.0, -10.0, -7.0, -4.0, -1.0, 1.0, 4.0, 7.0, 10.0, 13.0, 0.0]:
		var y := _roof_y(z) - 0.1
		kit.box("roof_detail", "purlin", Vector3(HX * 2.0, 0.18, 0.12), Transform3D(Basis.IDENTITY, Vector3(0, y, z)), 1.0, ["+y"])
	# fluorescent tubes hanging from the truss bottom chords
	for x: float in TRUSS_X:
		for z in [-10.5, -4.5, 4.5, 10.5]:
			kit.add("lamps", Transform3D(Basis.IDENTITY, Vector3(x, WALL_H, z)))


# ---------------------------------------------------------------- layout (per half)

func _container(set_name: String, pos: Vector3, yaw_deg: float, color: Color, footprint := true) -> Transform3D:
	var xf := _xf(pos, yaw_deg)
	kit.add(set_name, xf, color)
	var size := C40 if set_name == "c40" else C20
	if pos.y < 0.5:
		_ao(pos, Vector2(size.x + 0.05, size.z + (0.3 if set_name == "copen" else 0.05)), yaw_deg, 0.75, 0.8)
	if set_name == "copen":
		_open_container_colliders(xf)
		if footprint:
			# the two side walls only: the inside is a walkway
			for zs in [-1.0, 1.0]:
				_footprint(Vector3(6.058, C_H, 0.25), xf * Transform3D(Basis.IDENTITY, Vector3(0, C_H * 0.5, zs * 1.2)))
	else:
		_collider(size, xf * Transform3D(Basis.IDENTITY, Vector3(0, C_H * 0.5, 0)), footprint)
	return xf


func _open_container_colliders(xf: Transform3D) -> void:
	var path := Kit.PROPS + "container_open_colliders.json"
	var boxes: Array = []
	if FileAccess.file_exists(path):
		var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
		if data is Dictionary and (data as Dictionary).has("collision_boxes"):
			boxes = data.collision_boxes
	if boxes.is_empty():
		boxes = [{"center": [0, 1.2955, -1.1845], "size": [6.058, 2.591, 0.069]}, {"center": [0, 1.2955, 1.1845], "size": [6.058, 2.591, 0.069]},
			{"center": [0, 2.5305, 0], "size": [6.058, 0.121, 2.3]}, {"center": [0, 0.06, 0], "size": [6.058, 0.12, 2.3]}]
	for b in boxes:
		var c: Array = b.center
		var sz: Array = b.size
		var size := Vector3(sz[0], sz[1], sz[2])
		# thin sheet walls get a 0.2 m collider (no tunnelling, clean navmesh edges)
		if size.z < 0.2 and size.y > 1.0:
			size.z = 0.2
		_collider(size, xf * Transform3D(Basis.IDENTITY, Vector3(c[0], c[1], c[2])), false)


## Crates: cells = [[x, z, levels, yaw], ...] -> crate instances + one collider per stack.
func _crates(cells: Array) -> void:
	for cell in cells:
		var x: float = cell[0]
		var z: float = cell[1]
		var lv: int = cell[2]
		var yaw: float = cell[3] if cell.size() > 3 else 0.0
		var y0: float = cell[4] if cell.size() > 4 else 0.0
		for i in lv:
			kit.add("crate", _xf(Vector3(x, y0 + CRATE * i, z), yaw + (0.0 if i == 0 else (4.0 if i % 2 == 1 else -3.0))))
		_collider(Vector3(CRATE, CRATE * lv, CRATE), _xf(Vector3(x, y0 + CRATE * lv * 0.5, z), yaw), y0 < 0.5)
		if y0 < 0.5:
			_ao(Vector3(x, 0, z), Vector2(CRATE, CRATE), yaw, 0.38 + 0.08 * lv, 0.75)


func _barrels(spots: Array) -> void:
	var cols := [Color("2f63b0"), Color("c0362c"), Color("e6b422"), Color("2f63b0"), Color("3d8a52")]
	for i in spots.size():
		var s: Array = spots[i]
		var col: Color = cols[int(s[2]) % cols.size()] if s.size() > 2 else cols[i % cols.size()]
		kit.add("barrel", _xf(Vector3(s[0], 0, s[1]), float(i) * 47.0), col)
		_ao(Vector3(s[0], 0, s[1]), Vector2(0.45, 0.45), 0.0, 0.3, 0.6)
		_collider(Vector3(0.6, 0.9, 0.6), _xf(Vector3(s[0], 0.45, s[1])), true)


func _pallets(x: float, z: float, n: int, yaw := 0.0) -> void:
	for i in n:
		kit.add("pallet", _xf(Vector3(x, 0.144 * i, z), yaw + (6.0 if i % 2 == 1 else 0.0)))
	_collider(Vector3(1.2, 0.144 * n, 0.8), _xf(Vector3(x, 0.072 * n, z), yaw), true)
	_ao(Vector3(x, 0, z), Vector2(1.15, 0.75), yaw, 0.22, 0.55)


func _bollard(x: float, z: float) -> void:
	kit.add("bollard", _xf(Vector3(x, 0, z)))
	_collider(Vector3(0.2, 1.1, 0.2), _xf(Vector3(x, 0.55, z)), false)


## Steel ramp from the floor (bottom edge centre `a`) up to `b` (top edge centre), 2.4 m wide:
## diamond-plate deck, hazard-striped side plates, one thick box collider under the deck.
func _ramp(a: Vector3, b: Vector3, width := 2.4) -> void:
	kit.batch_config("ramps", 1, true)
	var wa := _p(a)
	var wb := _p(b)
	var d := (wb - wa).normalized()
	var horiz := Vector3(d.x, 0, d.z).normalized()
	var side := Vector3.UP.cross(horiz).normalized()
	var n := d.cross(side).normalized()
	if n.y < 0.0:
		n = -n
	var length := wa.distance_to(wb)
	var hw := width * 0.5
	# deck (top surface flush with the collider)
	var deck := [wa - side * hw, wa + side * hw, wb + side * hw, wb - side * hw]
	kit.quad("ramps", "diamond", deck, [Vector2(0, length), Vector2(width, length), Vector2(width, 0), Vector2(0, 0)], n)
	# side plates (vertical triangles from the floor to the deck edge) + a top rail strip
	for s in [-1.0, 1.0]:
		var o: Vector3 = side * (hw * s)
		var foot := Vector3(wb.x, 0, wb.z) + o
		var run := Vector2(wa.x, wa.z).distance_to(Vector2(wb.x, wb.z))
		kit.tri("ramps", "ramp_side", [wa + o, foot, wb + o], [Vector2(0, 0.6), Vector2(run, 0.6), Vector2(run, 0.6 - b.y)], side * s)
		kit.quad("ramps", "steel", [wa + o + n * 0.06, wb + o + n * 0.06, wb + o + side * (0.05 * s), wa + o + side * (0.05 * s)],
			[Vector2(0, 0), Vector2(length, 0), Vector2(length, 0.1), Vector2(0, 0.1)], (side * s + n).normalized())
	# kick plate at the bottom edge
	kit.quad("ramps", "steel", [wa - side * hw, wa + side * hw, wa + side * hw + n * 0.06, wa - side * hw + n * 0.06],
		[Vector2(0, 0), Vector2(width, 0), Vector2(width, 0.06), Vector2(0, 0.06)], -horiz)
	# collider: 3.2 m thick box whose top face is the deck; extended 0.6 m past the bottom edge
	var t := 3.2
	var ext := 0.6
	var basis := Basis(d, n, d.cross(n))
	var centre := wa + d * ((length - ext) * 0.5) - n * (t * 0.5)
	_body(Transform3D(basis, centre), Vector3(length + ext, t, width))
	# footprint = the visible ramp's floor rectangle
	var p0 := wa - side * hw
	var p1 := wa + side * hw
	var p2 := Vector3(wb.x, 0, wb.z) + side * hw
	var p3 := Vector3(wb.x, 0, wb.z) - side * hw
	var mn := Vector2(minf(minf(p0.x, p1.x), minf(p2.x, p3.x)), minf(minf(p0.z, p1.z), minf(p2.z, p3.z)))
	var mx := Vector2(maxf(maxf(p0.x, p1.x), maxf(p2.x, p3.x)), maxf(maxf(p0.z, p1.z), maxf(p2.z, p3.z)))
	obstacles.append(Rect2(mn, mx - mn))


## 20 ft container leaning lengthwise: low end on the floor at `low` (bottom edge centre), long
## axis toward `toward` (horizontal), tilted by `deg`. A second box fills the wedge underneath.
func _tilted(low: Vector3, toward: Vector3, deg: float, color: Color) -> void:
	var a := deg_to_rad(deg)
	var h := _dir(toward).normalized()
	var d := (h * cos(a) + Vector3.UP * sin(a)).normalized()
	var side := Vector3.UP.cross(h).normalized()
	var n := d.cross(side).normalized()
	if n.y < 0.0:
		n = -n
	var basis := Basis(d, n, d.cross(n))
	var origin := _p(low) + d * (C20.x * 0.5)
	kit.add("c20", Transform3D(basis, origin), color)
	_collider(C20, Transform3D(basis, origin + n * (C_H * 0.5)), true)
	_body(Transform3D(basis, origin - n * 1.5), Vector3(C20.x, 3.0, C20.z))


func _layout_half() -> void:
	var west := _side == 0
	# ---- central high ground: two 40 ft containers side by side (long axis across the hall)
	_container("c40", Vector3(-1.219, 0, 0), 90.0, LIGHT_BLUE if west else LIGHT_BLUE2)
	_ramp(Vector3(-7.2, 0, 2.75), Vector3(-2.44, C_H, 2.75))
	_ao(Vector3(-4.82, 0, 2.75), Vector2(4.76, 2.4), 0.0, 0.5, 0.6)
	_hazard_strip(Vector3(-7.45, 0, 1.55), Vector3(-7.45, 0, 3.95), 0.5)
	_crates([[-3.04, -4.7, 2, 0.0], [-4.24, -4.7, 1, 0.0]])
	_crates([[-1.5, -4.9, 1, 8.0, C_H]])                       # cover on the high ground
	# ---- long container along the south wall, walk-through container in the north-west
	_container("c40", Vector3(-4.4, 0, HZ - 1.75), 0.0, DEEP_BLUE if west else RUST)
	_container("copen", Vector3(-9.2, 0, -8.7), 0.0, ORANGE if west else Color("e8892e"))
	# ---- north-west corner: 2-high stack of 20 ft containers on a hatched pad
	_container("c20", Vector3(-17.2, 0, -HZ + 1.75), 0.0, RUST if west else DEEP_BLUE)
	_container("c20", Vector3(-17.0, C_H, -HZ + 1.8), 2.0, CREAM, false)
	_collider(Vector3(6.2, C_H, 2.5), _xf(Vector3(-17.1, C_H * 1.5, -HZ + 1.77)), false)
	_hatch_pad(Vector3(-17.9, 0, -8.9), Vector2(4.6, 4.2))
	_pallets(-20.3, -10.2, 3, 90.0)
	_pallets(-17.6, -8.0, 1, 15.0)
	_barrels([[-20.25, -6.1, 0], [-20.2, -5.45, 0], [-19.6, -5.8, 1]])
	# ---- south-west: support container + tilted container, forklift (east: tank) by the wall
	_container("c20", Vector3(-17.4, 0, HZ - 1.75), 0.0, LIGHT_BLUE if west else ORANGE)
	_tilted(Vector3(-15.9, 0, 6.95), Vector3(0, 0, 1), 27.0, RUST if west else CREAM)
	_ao(Vector3(-15.9, 0, 9.65), Vector2(2.44, 5.4), 0.0, 0.7, 0.7)
	if west:
		kit.add("forklift", _xf(Vector3(-11.95, 0, 13.2), 90.0))
	else:
		kit.add("tank", _xf(Vector3(-12.4, 0, 13.2), 0.0))
	# collider reaches the wall: no closed slot behind the vehicle
	_collider(Vector3(3.5, 2.4, 2.4), _xf(Vector3(-12.4, 1.2, 13.7)), true)
	_ao(Vector3(-12.4, 0, 13.4), Vector2(3.3, 1.9), 0.0, 0.5, 0.7)
	_hatch_pad(Vector3(-18.9, 0, 8.9), Vector2(3.4, 4.4))
	_pallets(-19.6, 10.1, 2, 0.0)
	_bollard(-14.0, 11.5)
	_bollard(-10.8, 11.5)
	_barrels([[-3.2, 11.45, 2], [-2.55, 11.6, 1]])
	_crates([[-6.9, 8.2, 2, 0.0], [-5.7, 8.2, 1, 0.0]])
	_barrels([[-11.3, 2.7, 0], [-11.0, 3.35, 2], [-11.85, 3.15, 1]])
	# ---- spawn approach
	_crates([[-15.3, -0.6, 2, 0.0], [-15.3, 0.6, 1, 0.0]])
	_crates([[-10.6, -2.9, 1, 0.0], [-10.6, -1.7, 1, 0.0]])
	_crates([[-0.6, -9.4, 1, 0.0]])
	_pallets(-9.6, 5.8, 2, 0.0)
	for z in [-3.75, 3.75]:
		_bollard(-HX + 0.55, z)
	_hazard_strip(Vector3(-HX + 0.25, 0, -AL_HW), Vector3(-HX + 0.25, 0, AL_HW), 0.5)
	_floor_sign(0 if west else 1, Vector3(-18.3, 0, 0), 2.0, -90.0)
	# ---- floor wear
	_stain(1, Vector3(-12.6, 0, -4.4), Vector2(1.6, 1.6), 20.0, 0.9)
	_stain(1, Vector3(-6.2, 0, 6.4), Vector2(1.1, 1.1), 70.0, 0.8)
	_stain(1, Vector3(-17.2, 0, 3.9), Vector2(0.9, 0.9), 140.0, 0.8)
	_stain(2, Vector3(-19.4, 0, 12.0), Vector2(2.6, 2.6), 0.0, 1.0)
	_stain(2, Vector3(-4.2, 0, -11.0), Vector2(2.4, 2.4), 45.0, 0.9)
	_stain(2, Vector3(-14.0, 0, -6.2), Vector2(2.2, 2.2), 10.0, 0.8)
	_stain(3, Vector3(-9.0, 0, 10.2), Vector2(3.8, 1.7), 12.0, 0.9)
	_stain(3, Vector3(-3.4, 0, -7.7), Vector2(4.2, 1.8), -8.0, 0.75)
	# ---- lane markings
	_dashed_line(Vector3(-13.0, 0, -6.4), Vector3(-3.6, 0, -6.4))
	_dashed_line(Vector3(-13.0, 0, 6.4), Vector3(-8.0, 0, 6.4))
	_dashed_line(Vector3(-19.6, 0, -4.6), Vector3(-19.6, 0, 4.6))


# ---------------------------------------------------------------- AI helpers

func _make_cover_points() -> void:
	for rect in obstacles:
		var pts: Array[Vector3] = []
		var margin := 0.95
		var x0 := rect.position.x - margin
		var x1 := rect.end.x + margin
		var z0 := rect.position.y - margin
		var z1 := rect.end.y + margin
		var nx := maxi(1, int(rect.size.x / 2.0))
		var nz := maxi(1, int(rect.size.y / 2.0))
		for i in nx + 1:
			var x := lerpf(rect.position.x, rect.end.x, float(i) / nx)
			pts.append(Vector3(x, 0, z0))
			pts.append(Vector3(x, 0, z1))
		for j in nz + 1:
			var z := lerpf(rect.position.y, rect.end.y, float(j) / nz)
			pts.append(Vector3(x0, 0, z))
			pts.append(Vector3(x1, 0, z))
		for p in pts:
			if absf(p.x) > HX - 0.8 or absf(p.z) > HZ - 0.8:
				continue
			var inside := false
			for other in obstacles:
				if other.grow(0.45).has_point(Vector2(p.x, p.z)):
					inside = true
					break
			if not inside:
				cover_points.append(p)
