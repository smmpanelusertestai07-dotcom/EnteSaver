class_name MapBuilder
extends RefCounted
## Builds the Lone Wolf arena: ground, perimeter walls, cover props (containers, crates,
## barriers, sandbags, rocks, a house), decoration, colliders, navmesh source, cover
## points and minimap footprints. The layout has 180-degree rotational symmetry so both
## spawns are equally fair.

const HALF := 40.0
const PROPS := "res://assets/props/"
const TEX := "res://assets/textures/"

var nav: NavigationRegion3D
var deco: Node3D
var env: WorldEnvironment
var sun: DirectionalLight3D
var obstacles: Array[Rect2] = []
var cover_points: Array[Vector3] = []
var spawn_a := Vector3(0, 0, -35)
var spawn_b := Vector3(0, 0, 35)
var spawn_a_yaw := PI
var spawn_b_yaw := 0.0
var map_name := "CARGO CAGE"
var map_rect := Rect2(-HALF, -HALF, HALF * 2.0, HALF * 2.0)
var zone_center := Vector3.ZERO
var zone_start_radius := 50.0
var _scenes := {}
var _mats := {}


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
	nm.filter_baking_aabb = AABB(Vector3(-HALF, -1.0, -HALF), Vector3(HALF * 2.0, 8.0, HALF * 2.0))
	nav.navigation_mesh = nm
	deco = Node3D.new()
	deco.name = "Decor"
	parent.add_child(deco)
	_build_environment(parent)
	_ground()
	_walls()
	_layout()
	_decor()
	_make_cover_points()


# ---------------------------------------------------------------- environment / API

func _build_environment(parent: Node3D) -> void:
	env = WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	var sm := ProceduralSkyMaterial.new()
	sm.sky_top_color = Color(0.22, 0.45, 0.84)
	sm.sky_horizon_color = Color(0.7, 0.81, 0.93)
	sky.sky_material = sm
	e.sky = sky
	e.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	e.ambient_light_energy = 0.65
	e.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	e.glow_enabled = true
	env.environment = e
	parent.add_child(env)
	sun = DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-48, -35, 0)
	sun.light_energy = 1.15
	sun.shadow_enabled = true
	parent.add_child(sun)


## Red spawn barriers during the prep phase (colliders + glow).
func set_barriers(_on: bool) -> void:
	pass


## Graphics quality 0..3 (SMOOTH..MAX): decoration density, shadows on small props.
func apply_quality(_g: int) -> void:
	pass


# ---------------------------------------------------------------- materials

func _tex(name: String) -> Texture2D:
	var path := TEX + name + ".png"
	return load(path) if ResourceLoader.exists(path) else null


func mat(kind: String) -> StandardMaterial3D:
	if _mats.has(kind):
		return _mats[kind]
	var m := StandardMaterial3D.new()
	m.roughness = 0.85
	var tex: Texture2D = null
	var normal: Texture2D = null
	var scale := 0.25
	match kind:
		"asphalt":
			tex = _tex("asphalt")
			normal = _tex("asphalt_n")
			m.albedo_color = Color(0.82, 0.82, 0.84)
			scale = 0.12
		"grass":
			tex = _tex("grass")
			m.albedo_color = Color(0.85, 0.95, 0.8)
			scale = 0.08
		"dirt":
			tex = _tex("dirt")
			scale = 0.15
		"concrete":
			tex = _tex("concrete")
			normal = _tex("concrete_n")
			m.albedo_color = Color(0.92, 0.9, 0.86)
			scale = 0.22
		"wall":
			tex = _tex("concrete")
			normal = _tex("concrete_n")
			m.albedo_color = Color(0.93, 0.86, 0.74)
			scale = 0.25
		"brick":
			tex = _tex("brick")
			normal = _tex("brick_n")
			scale = 0.35
		"roof":
			tex = _tex("tiles")
			m.albedo_color = Color(0.55, 0.42, 0.38)
			scale = 0.35
		"wood":
			tex = _tex("wood_planks")
			normal = _tex("wood_planks_n")
			m.albedo_color = Color(0.95, 0.85, 0.7)
			scale = 0.6
		"wood_dark":
			tex = _tex("wood_planks")
			m.albedo_color = Color(0.55, 0.42, 0.3)
			scale = 0.6
		"sandbag":
			tex = _tex("sandbag")
			m.albedo_color = Color(0.85, 0.78, 0.62)
			scale = 0.8
		"metal":
			tex = _tex("metal_painted")
			m.albedo_color = Color(0.38, 0.4, 0.43)
			m.metallic = 0.6
			m.roughness = 0.5
			scale = 0.4
		"rubber":
			m.albedo_color = Color(0.08, 0.08, 0.09)
		"rock":
			tex = _tex("concrete")
			m.albedo_color = Color(0.6, 0.6, 0.58)
			scale = 0.3
		"leaves":
			m.albedo_color = Color(0.27, 0.52, 0.22)
			m.roughness = 0.9
		"leaves2":
			m.albedo_color = Color(0.36, 0.6, 0.24)
		"bark":
			m.albedo_color = Color(0.36, 0.25, 0.17)
		"mountain":
			m.albedo_color = Color(0.43, 0.5, 0.45)
		"snow":
			m.albedo_color = Color(0.95, 0.96, 0.98)
		"stripe":
			m.albedo_color = Color(0.95, 0.75, 0.1)
		"glass":
			m.albedo_color = Color(0.5, 0.65, 0.75, 0.6)
			m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			m.roughness = 0.1
		"lamp":
			m.albedo_color = Color(1.0, 0.95, 0.8)
			m.emission_enabled = true
			m.emission = Color(1.0, 0.9, 0.7)
			m.emission_energy_multiplier = 2.0
		_:
			if kind.begins_with("paint_"):
				tex = _tex("metal_painted")
				var hexs := kind.substr(6)
				m.albedo_color = Color.html(hexs)
				m.metallic = 0.3
				m.roughness = 0.6
				scale = 0.35
	if tex:
		m.albedo_texture = tex
		m.uv1_triplanar = true
		m.uv1_world_triplanar = true
		m.uv1_scale = Vector3.ONE * scale
	if normal:
		m.normal_enabled = true
		m.normal_texture = normal
		m.normal_scale = 0.6
	m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	_mats[kind] = m
	return m


# ---------------------------------------------------------------- helpers

func _box_visual(parent: Node3D, size: Vector3, xf: Transform3D, m: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	mi.material_override = m
	parent.add_child(mi)
	mi.transform = xf
	return mi


func _collider(size: Vector3, xf: Transform3D, footprint := true) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.collision_layer = Fighter.LAYER_WORLD
	body.collision_mask = 0
	var cs := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = size
	cs.shape = bs
	body.add_child(cs)
	nav.add_child(body)
	body.transform = xf
	if footprint:
		var ext := (xf.basis * size).abs()
		var c := xf.origin
		obstacles.append(Rect2(Vector2(c.x - ext.x * 0.5, c.z - ext.z * 0.5), Vector2(ext.x, ext.z)))
	return body


func _prop_scene(file: String) -> PackedScene:
	if _scenes.has(file):
		return _scenes[file]
	var path := PROPS + file + ".glb"
	var ps: PackedScene = load(path) if ResourceLoader.exists(path) else null
	_scenes[file] = ps
	return ps


## Instantiates a prop GLB with material overrides by material name. Returns null if missing.
func _prop(file: String, xf: Transform3D, overrides := {}, parent: Node3D = null) -> Node3D:
	var ps := _prop_scene(file)
	if ps == null:
		return null
	var inst: Node3D = ps.instantiate()
	(parent if parent else deco).add_child(inst)
	inst.transform = xf
	for mi in inst.find_children("*", "MeshInstance3D", true, false):
		var m := mi as MeshInstance3D
		if m.mesh == null:
			continue
		for s in m.mesh.get_surface_count():
			var src := m.get_active_material(s)
			var mname := (src.resource_name if src else "").to_lower()
			for key: String in overrides:
				if mname.contains(key.to_lower()):
					m.set_surface_override_material(s, mat(String(overrides[key])))
					break
	return inst


func _xf(pos: Vector3, rot_deg := 0.0, scale := 1.0) -> Transform3D:
	return Transform3D(Basis(Vector3.UP, deg_to_rad(rot_deg)).scaled(Vector3.ONE * scale), pos)


# ---------------------------------------------------------------- ground and walls

func _ground() -> void:
	var outer := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(900, 900)
	outer.mesh = pm
	outer.material_override = mat("grass")
	outer.position.y = -0.02
	deco.add_child(outer)
	var inner := MeshInstance3D.new()
	var pm2 := PlaneMesh.new()
	pm2.size = Vector2(HALF * 2.0, HALF * 2.0)
	inner.mesh = pm2
	inner.material_override = mat("asphalt")
	deco.add_child(inner)
	var pad := MeshInstance3D.new()
	var pm3 := PlaneMesh.new()
	pm3.size = Vector2(18, 16)
	pad.mesh = pm3
	pad.material_override = mat("concrete")
	pad.position.y = 0.01
	deco.add_child(pad)
	for z in [-26.0, 26.0]:
		var line := MeshInstance3D.new()
		var lm := PlaneMesh.new()
		lm.size = Vector2(30, 0.3)
		line.mesh = lm
		var lmat := StandardMaterial3D.new()
		lmat.albedo_color = Color(0.95, 0.85, 0.3)
		line.material_override = lmat
		line.position = Vector3(0, 0.015, z)
		deco.add_child(line)
	_collider(Vector3(400, 2, 400), _xf(Vector3(0, -1, 0)), false)


func _walls() -> void:
	var h := 4.2
	var t := 0.6
	var wall_mat := mat("concrete")
	for side in 4:
		var horizontal := side < 2
		var sgn := -1.0 if side % 2 == 0 else 1.0
		var size := Vector3(HALF * 2.0 + t * 2.0, h, t) if horizontal else Vector3(t, h, HALF * 2.0)
		var pos := Vector3(0, h * 0.5, sgn * (HALF + t * 0.5)) if horizontal else Vector3(sgn * (HALF + t * 0.5), h * 0.5, 0)
		_box_visual(deco, size, _xf(pos), wall_mat)
		_collider(size, _xf(pos), false)
		var trim := size
		trim.y = 0.25
		trim.x += 0.1 if horizontal else 0.2
		trim.z += 0.2 if horizontal else 0.1
		_box_visual(deco, trim, _xf(pos + Vector3(0, h * 0.5 + 0.12, 0)), mat("metal"))
	# Pillars along the walls for visual rhythm.
	for i in range(-4, 5):
		var x := i * 10.0
		for z in [-HALF - 0.3, HALF + 0.3]:
			_box_visual(deco, Vector3(0.9, 4.6, 0.9), _xf(Vector3(x, 2.3, z)), mat("wall"))
		for zx in [-HALF - 0.3, HALF + 0.3]:
			_box_visual(deco, Vector3(0.9, 4.6, 0.9), _xf(Vector3(zx, 2.3, x)), mat("wall"))


# ---------------------------------------------------------------- cover layout

func _pair(fn: Callable, pos: Vector3, rot: float, extra: Variant = null) -> void:
	## Places an object and its 180-degree rotated twin.
	fn.call(pos, rot, extra)
	fn.call(Vector3(-pos.x, pos.y, -pos.z), rot + 180.0, extra)


func _layout() -> void:
	_house(Vector3.ZERO, 0.0)
	_pair(_container, Vector3(-12, 0, -11), 0.0, "B83A2F")
	_pair(_container, Vector3(14, 0, -15), 90.0, "2F7D4A")
	_pair(_container, Vector3(14, 2.59, -15), 90.0, "2F7D4A")
	_pair(_container, Vector3(-27, 0, -3), 90.0, "2F5FA8")
	_pair(_container, Vector3(26, 0, -24), 0.0, "D98A1E")
	_pair(_crate_stack, Vector3(-5, 0, -25), 0.0, 2)
	_pair(_crate_stack, Vector3(6, 0, -27), 20.0, 1)
	_pair(_crate_stack, Vector3(-19, 0, -16), 0.0, 3)
	_pair(_crate_stack, Vector3(20, 0, -5), 0.0, 2)
	_pair(_crate_stack, Vector3(-33, 0, -24), 0.0, 2)
	_pair(_crate_stack, Vector3(9, 0, -6), 0.0, 1)
	_pair(_barrier, Vector3(0, 0, -19), 0.0, null)
	_pair(_barrier, Vector3(-9, 0, -31), 0.0, null)
	_pair(_barrier, Vector3(32, 0, -12), 90.0, null)
	_pair(_barrier, Vector3(-20, 0, -30), 90.0, null)
	_pair(_sandbags, Vector3(4, 0, -32), 0.0, null)
	_pair(_sandbags, Vector3(-30, 0, -14), 90.0, null)
	_pair(_rock, Vector3(23, 0, -31), 30.0, null)
	_pair(_rock, Vector3(-24, 0, 9), 70.0, null)


func _container(pos: Vector3, rot: float, color: Variant) -> void:
	var size := Vector3(6.06, 2.59, 2.44)
	var xf := _xf(pos, rot)
	var inst := _prop("container", xf, {"paint": "paint_" + String(color), "metal": "metal", "rubber": "rubber"})
	if inst == null:
		_box_visual(deco, size, _xf(pos + Vector3(0, size.y * 0.5, 0), rot), mat("paint_" + String(color)))
	_collider(size, _xf(pos + Vector3(0, size.y * 0.5, 0), rot), pos.y < 0.5)


func _crate(pos: Vector3, rot: float) -> void:
	var s := 1.2
	if _prop("crate", _xf(pos, rot), {"wooddark": "wood_dark", "wood": "wood"}) == null:
		_box_visual(deco, Vector3.ONE * s, _xf(pos + Vector3(0, s * 0.5, 0), rot), mat("wood"))
	_collider(Vector3.ONE * s, _xf(pos + Vector3(0, s * 0.5, 0), rot), pos.y < 0.5)


func _crate_stack(pos: Vector3, rot: float, count: Variant) -> void:
	var n := int(count)
	var basis := Basis(Vector3.UP, deg_to_rad(rot))
	_crate(pos, rot)
	if n >= 2:
		_crate(pos + basis * Vector3(1.25, 0, 0), rot)
	if n >= 3:
		_crate(pos + Vector3(0.6, 1.2, 0) + basis * Vector3(0.0, 0, 0), rot + 8.0)


func _barrier(pos: Vector3, rot: float, _x: Variant) -> void:
	var size := Vector3(3.0, 0.81, 0.6)
	if _prop("barrier", _xf(pos, rot), {"concrete": "concrete", "stripe": "stripe"}) == null:
		_box_visual(deco, size, _xf(pos + Vector3(0, size.y * 0.5, 0), rot), mat("concrete"))
	_collider(size, _xf(pos + Vector3(0, size.y * 0.5, 0), rot))


func _sandbags(pos: Vector3, rot: float, _x: Variant) -> void:
	var size := Vector3(2.5, 0.9, 0.7)
	if _prop("sandbags", _xf(pos, rot), {"sandbag": "sandbag"}) == null:
		_box_visual(deco, size, _xf(pos + Vector3(0, size.y * 0.5, 0), rot), mat("sandbag"))
	_collider(size, _xf(pos + Vector3(0, size.y * 0.5, 0), rot))


func _rock(pos: Vector3, rot: float, _x: Variant) -> void:
	var size := Vector3(1.76, 1.08, 1.41)
	if _prop("rock", _xf(pos, rot, 1.1), {"rock": "rock"}) == null:
		_box_visual(deco, size, _xf(pos + Vector3(0, size.y * 0.5, 0), rot), mat("rock"))
	_collider(size, _xf(pos + Vector3(0, size.y * 0.5, 0), rot))


## Single-storey house: the modeled GLB plus its exact collider boxes when available,
## otherwise a procedural version with door openings on +/-Z and windows on +/-X.
func _house(pos: Vector3, rot: float) -> void:
	var meta_path := PROPS + "house_colliders.json"
	if _prop_scene("house") and FileAccess.file_exists(meta_path):
		var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(meta_path))
		if data is Dictionary and (data as Dictionary).has("collision_boxes"):
			var xf := _xf(pos, rot)
			_prop("house", xf, {"wall": "wall", "trim": "concrete", "roof": "roof"})
			for b in data.collision_boxes:
				var c: Array = b.center
				var sz: Array = b.size
				var local := Transform3D(Basis.IDENTITY, Vector3(c[0], c[1], c[2]))
				_collider(Vector3(sz[0], sz[1], sz[2]), xf * local, false)
			var ext := (xf.basis * Vector3(7.0, 3.0, 6.0)).abs()
			obstacles.append(Rect2(Vector2(pos.x - ext.x * 0.5, pos.z - ext.z * 0.5), Vector2(ext.x, ext.z)))
			return
	var w := 7.0
	var d := 6.0
	var h := 3.0
	var t := 0.25
	var root := Node3D.new()
	root.name = "House"
	deco.add_child(root)
	root.transform = _xf(pos, rot)
	var segs: Array = []
	# +/-Z walls with a centered door (1.4 wide, 2.3 tall).
	for zs: float in [-1.0, 1.0]:
		var z := zs * (d * 0.5 - t * 0.5)
		var side_w := (w - 1.4) * 0.5
		segs.append([Vector3(side_w, h, t), Vector3(-(1.4 * 0.5 + side_w * 0.5), h * 0.5, z)])
		segs.append([Vector3(side_w, h, t), Vector3(1.4 * 0.5 + side_w * 0.5, h * 0.5, z)])
		segs.append([Vector3(1.4, h - 2.3, t), Vector3(0, 2.3 + (h - 2.3) * 0.5, z)])
	# +/-X walls with two windows (1.2 wide, sill 1.0, top 2.1).
	for xs: float in [-1.0, 1.0]:
		var x := xs * (w * 0.5 - t * 0.5)
		var inner := d - t * 2.0
		var win_c := [-1.3, 1.3]
		var edges := [-inner * 0.5, win_c[0] - 0.6, win_c[0] + 0.6, win_c[1] - 0.6, win_c[1] + 0.6, inner * 0.5]
		for k in [0, 2, 4]:
			var a: float = edges[k]
			var b: float = edges[k + 1]
			segs.append([Vector3(t, h, b - a), Vector3(x, h * 0.5, (a + b) * 0.5)])
		for wc: float in win_c:
			segs.append([Vector3(t, 1.0, 1.2), Vector3(x, 0.5, wc)])
			segs.append([Vector3(t, h - 2.1, 1.2), Vector3(x, 2.1 + (h - 2.1) * 0.5, wc)])
	var wall_m := mat("wall")
	for s in segs:
		var size: Vector3 = s[0]
		var local := Transform3D(Basis.IDENTITY, s[1])
		_box_visual(root, size, local, wall_m)
		_collider(size, root.transform * local, false)
	var roof_size := Vector3(w + 0.5, 0.22, d + 0.5)
	var roof_xf := Transform3D(Basis.IDENTITY, Vector3(0, h + 0.11, 0))
	_box_visual(root, roof_size, roof_xf, mat("roof"))
	_collider(roof_size, root.transform * roof_xf, false)
	_box_visual(root, Vector3(w + 0.3, 0.12, d + 0.3), Transform3D(Basis.IDENTITY, Vector3(0, 0.06, 0)), mat("concrete"))
	for zs: float in [-1.0, 1.0]:
		_box_visual(root, Vector3(1.6, 0.15, 0.3), Transform3D(Basis.IDENTITY, Vector3(0, 2.38, zs * (d * 0.5))), mat("metal"))
	var ext := (root.transform.basis * Vector3(w, h, d)).abs()
	obstacles.append(Rect2(Vector2(pos.x - ext.x * 0.5, pos.z - ext.z * 0.5), Vector2(ext.x, ext.z)))


# ---------------------------------------------------------------- decoration

func _decor() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	if _prop_scene("mountains"):
		_prop("mountains", _xf(Vector3.ZERO), {"mountain": "mountain", "snow": "snow"})
	for i in 70:
		var ang := rng.randf() * TAU
		var r := rng.randf_range(HALF + 8.0, 120.0)
		var p := Vector3(cos(ang) * r, 0, sin(ang) * r)
		var file := "tree_pine" if rng.randf() < 0.6 else "tree_round"
		var inst := _prop(file, _xf(p, rng.randf() * 360.0, rng.randf_range(0.8, 1.35)), {"leaves": "leaves" if file == "tree_pine" else "leaves2", "bark": "bark"})
		if inst == null:
			_fallback_tree(p, rng.randf_range(0.8, 1.3))
	for corner in [Vector3(-36, 0, -36), Vector3(36, 0, 36)]:
		var tw := _prop("watchtower", _xf(corner, 45.0), {"wood": "wood", "metal": "metal"})
		if tw:
			for lx in [-1.4, 1.4]:
				for lz in [-1.4, 1.4]:
					var off := Basis(Vector3.UP, deg_to_rad(45.0)) * Vector3(lx, 2.0, lz)
					_collider(Vector3(0.3, 4.0, 0.3), _xf(corner + off), false)
			obstacles.append(Rect2(Vector2(corner.x - 1.5, corner.z - 1.5), Vector2(3, 3)))
	for i in range(-3, 4):
		for z in [-HALF + 1.2, HALF - 1.2]:
			var lp := _prop("lamp_post", _xf(Vector3(i * 12.0, 0, z), 0.0 if z < 0 else 180.0), {"lamp": "lamp", "metal": "metal", "light": "lamp", "bulb": "lamp"})
			if lp:
				_collider(Vector3(0.25, 5.0, 0.25), _xf(Vector3(i * 12.0, 2.5, z)), false)


func _fallback_tree(p: Vector3, s: float) -> void:
	var trunk := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = 0.15
	cm.bottom_radius = 0.25
	cm.height = 2.5
	trunk.mesh = cm
	trunk.material_override = mat("bark")
	deco.add_child(trunk)
	trunk.transform = _xf(p + Vector3(0, 1.25 * s, 0), 0.0, s)
	var crown := MeshInstance3D.new()
	var cone := CylinderMesh.new()
	cone.top_radius = 0.0
	cone.bottom_radius = 1.8
	cone.height = 5.0
	cone.radial_segments = 7
	crown.mesh = cone
	crown.material_override = mat("leaves")
	deco.add_child(crown)
	crown.transform = _xf(p + Vector3(0, 4.5 * s, 0), 0.0, s)


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
			if absf(p.x) > HALF - 1.0 or absf(p.z) > HALF - 1.0:
				continue
			var inside := false
			for other in obstacles:
				if other.grow(0.4).has_point(Vector2(p.x, p.z)):
					inside = true
					break
			if not inside:
				cover_points.append(p)
