extends RefCounted
## Geometry + material toolkit used by MapBuilder (the "CARGO CAGE" warehouse):
##  - a material library by key (tiled textures, saturated colours, emissive lamps),
##  - merged static meshes ("batches": boxes / quads / triangles with world-scaled UVs, one
##    surface per material, one draw call per material),
##  - MultiMesh prop sets made from the GLB props in assets/props (materials overridden by the
##    material NAME, optional per-instance colours that multiply the Paint albedo), with simple
##    fallback meshes while a prop file does not exist yet.
## Everything is built once at load; nothing here runs per frame.

const PROPS := "res://assets/props/"
const TEX := "res://assets/textures/"

var _mats := {}
var _texs := {}
var _parts := {}        # prop file -> [[Mesh, Transform3D], ...] ([] if the file is missing)
var _batches := {}      # batch name -> {"st": {mat_key: SurfaceTool}, "layers": int, "shadow": bool, "order": []}
var _sets := {}         # set name -> {"file", "xforms", "colors", "overrides", "shadow", "layers", "colors_on"}
var _set_order: Array[String] = []


# ---------------------------------------------------------------- textures / materials

func tex(file: String) -> Texture2D:
	if _texs.has(file):
		return _texs[file]
	var path := TEX + file + ".png"
	var t: Texture2D = load(path) if ResourceLoader.exists(path) else null
	_texs[file] = t
	return t


func _std(color: Color, rough := 0.8, metal := 0.0) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = rough
	m.metallic = metal
	m.metallic_specular = 0.45
	m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	return m


func _set_tex(m: StandardMaterial3D, albedo: String, normal := "", nscale := 1.0) -> void:
	var a := tex(albedo) if albedo != "" else null
	if a:
		m.albedo_texture = a
	var n := tex(normal) if normal != "" else null
	if n:
		m.normal_enabled = true
		m.normal_texture = n
		m.normal_scale = nscale


func _emissive(color: Color, energy: float) -> StandardMaterial3D:
	var m := _std(Color(0.08, 0.08, 0.08), 0.5)
	m.emission_enabled = true
	m.emission = color
	m.emission_energy_multiplier = energy
	return m


## Material by key. Keys used by the map (see MapBuilder): floor, paint (instance colours),
## wall_lower / wall_upper, steel, frame, window, roof, truss, purlin, lamp, lamp_housing,
## crate / crate_dark, pallet / pallet_dark, wood_floor, metal, metal_dark, rubber, yellow,
## black, red_paint, glass_small, shutter, diamond, ramp_side, hazard, hatch, line_paint,
## signs, header, white_cap, barrier, barrier_floor, barrier_fog, tank, fork_body, ...
func mat(key: String) -> Material:
	if _mats.has(key):
		return _mats[key]
	var m: Material = _make(key)
	_mats[key] = m
	return m


func _make(key: String) -> Material:
	var m: StandardMaterial3D
	match key:
		"floor":
			# polished slab concrete, UVs come from the floor mesh (1 UV = one 4 m slab)
			m = _std(Color(0.74, 0.74, 0.75), 0.6)
			_set_tex(m, "floor_concrete", "floor_concrete_n", 0.55)
		"paint":
			# container paint: near-white texture x per-instance colour (MultiMesh colours)
			m = _std(Color(1, 1, 1), 0.58, 0.18)
			_set_tex(m, "container_paint")
			m.vertex_color_use_as_albedo = true
			m.vertex_color_is_srgb = true
			# box-projected prop UVs are in metres (V = 1 - height): one tile = 4 m wide and
			# exactly one container height (2.591 m), top edge at V = 0
			m.uv1_scale = Vector3(0.25, 1.0 / 2.591, 1.0)
			m.uv1_offset = Vector3(0.0, 1.0 - 1.0 / 2.591, 0.0)
		"barrel_paint":
			m = _std(Color(1, 1, 1), 0.5, 0.3)
			_set_tex(m, "metal_painted")
			m.vertex_color_use_as_albedo = true
			m.vertex_color_is_srgb = true
			m.uv1_scale = Vector3(0.6, 0.6, 1.0)
		"wall_lower", "wall_upper":
			m = _std(Color("d98a2b") if key == "wall_lower" else Color("c9ced5"), 0.68, 0.05)
			_set_tex(m, "wall_grime")
			# one bay = 6 x 9 m (bay UVs in metres, centred on the bay, V = 1 - height)
			m.uv1_scale = Vector3(1.0 / 6.0, 1.0 / 9.0, 1.0)
			m.uv1_offset = Vector3(0.5, 8.0 / 9.0, 0.0)
		"header":
			# corrugated cladding on the flat lintel boxes above the spawn doors
			m = _std(Color("c9ced5"), 0.68, 0.05)
			_set_tex(m, "wall_grime", "corrugated_n", 0.9)
			m.uv1_scale = Vector3(1.0 / 6.0, 1.0 / 9.0, 1.0)
		"steel":
			m = _std(Color(0.3, 0.32, 0.35), 0.45, 0.55)
		"frame":
			m = _std(Color(0.22, 0.24, 0.27), 0.5, 0.35)
		"window":
			m = _emissive(Color(0.86, 0.93, 1.0), 1.7)
		"roof":
			# underside of the roof sheets: faces away from the sun, so a little self-light keeps
			# it a light warehouse grey instead of a dark lid
			m = _std(Color(0.86, 0.87, 0.9), 0.6, 0.1)
			_set_tex(m, "metal_painted", "corrugated_n", 1.0)
			m.emission_enabled = true
			m.emission = Color(0.36, 0.37, 0.39)
			m.emission_energy_multiplier = 1.0
		"truss", "purlin":
			m = _std(Color("5e3a26") if key == "truss" else Color("4f3122"), 0.65, 0.3)
		"lamp":
			m = _emissive(Color(0.9, 0.96, 1.0), 4.5)
		"lamp_housing":
			m = _std(Color(0.9, 0.92, 0.94), 0.4, 0.25)
		"crate":
			m = _std(Color(1.0, 0.97, 0.93), 0.8)
			_set_tex(m, "crate_wood")
			m.uv1_scale = Vector3(0.8, 0.8, 1.0)
		"crate_dark":
			m = _std(Color(0.66, 0.6, 0.55), 0.85)
			_set_tex(m, "crate_wood")
			m.uv1_scale = Vector3(0.8, 0.8, 1.0)
		"pallet":
			m = _std(Color(0.95, 0.8, 0.58), 0.8)
			_set_tex(m, "wood_planks")
			m.uv1_scale = Vector3(1.2, 1.2, 1.0)
		"pallet_dark":
			m = _std(Color(0.62, 0.47, 0.32), 0.85)
			_set_tex(m, "wood_planks")
			m.uv1_scale = Vector3(1.2, 1.2, 1.0)
		"wood_floor":
			m = _std(Color(0.78, 0.6, 0.42), 0.8)
			_set_tex(m, "wood_planks")
			m.uv1_scale = Vector3(0.6, 0.6, 1.0)
		"metal":
			m = _std(Color(0.56, 0.59, 0.62), 0.4, 0.7)
		"metal_dark":
			m = _std(Color(0.22, 0.23, 0.25), 0.5, 0.55)
		"rubber":
			m = _std(Color(0.05, 0.05, 0.05), 0.9)
		"yellow":
			m = _std(Color("f2c200"), 0.5, 0.1)
		"black":
			m = _std(Color(0.06, 0.06, 0.065), 0.65)
		"red_paint":
			m = _std(Color("c81e1e"), 0.45, 0.25)
		"glass_small":
			m = _std(Color(0.55, 0.68, 0.78), 0.1, 0.3)
		"shutter":
			m = _std(Color(0.74, 0.77, 0.8), 0.5, 0.35)
			_set_tex(m, "metal_painted")
			m.uv1_scale = Vector3(0.5, 0.5, 1.0)
		"diamond":
			m = _std(Color(0.88, 0.9, 0.94), 0.42, 0.6)
			_set_tex(m, "diamond_plate", "diamond_plate_n", 1.0)
			m.uv1_scale = Vector3(1.6, 1.6, 1.0)
		"ramp_side", "hazard":
			# yellow/black safety stripes; geometry UVs are in metres, the 1024 x 256 texture
			# covers 4 m x 1 m (square texels, 45-degree stripes)
			m = _std(Color(1, 1, 1), 0.6, 0.05)
			_set_tex(m, "hazard_stripes")
			m.uv1_scale = Vector3(0.25, 1.0, 1.0)
		"hatch":
			m = _std(Color(1, 1, 1), 0.7)
			_set_tex(m, "floor_hatch")
			m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			m.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
			m.cull_mode = BaseMaterial3D.CULL_BACK
		"line_paint":
			m = _std(Color("e8b71a"), 0.6)
		"signs":
			m = _std(Color(1, 1, 1), 0.55)
			_set_tex(m, "signs")
			m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
			m.alpha_scissor_threshold = 0.5
		"void":
			m = _std(Color(0.1, 0.11, 0.13), 1.0)
			m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		"white_cap":
			# top of the walls, only seen by the top-down minimap camera (white outline)
			m = _std(Color(0.96, 0.97, 0.98), 0.9)
			m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		"tank":
			m = _std(Color(0.8, 0.83, 0.86), 0.3, 0.75)
		"fork_body":
			m = _std(Color("f0a818"), 0.5, 0.2)
		"concrete":
			m = _std(Color(0.78, 0.77, 0.74), 0.85)
			_set_tex(m, "concrete")
			m.uv1_scale = Vector3(0.5, 0.5, 1.0)
		"barrier":
			return _barrier_shader(false)
		"barrier_floor":
			return _barrier_shader(true)
		"barrier_fog":
			var f := StandardMaterial3D.new()
			f.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			f.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			f.albedo_color = Color(1.0, 0.12, 0.08, 0.2)
			f.cull_mode = BaseMaterial3D.CULL_DISABLED
			f.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
			f.disable_receive_shadows = true
			return f
		_:
			m = _std(Color(0.6, 0.6, 0.6))
	return m


func _barrier_shader(floor_strip: bool) -> ShaderMaterial:
	var sh := Shader.new()
	if floor_strip:
		sh.code = """
shader_type spatial;
render_mode unshaded, cull_disabled, shadows_disabled, depth_draw_never, blend_add;
void fragment() {
	float edge = smoothstep(0.0, 0.35, UV.y) * smoothstep(1.0, 0.65, UV.y);
	float pulse = 0.8 + 0.2 * sin(TIME * 5.0);
	ALBEDO = vec3(1.0, 0.16, 0.08) * (0.6 + 1.6 * edge) * pulse;
}
"""
	else:
		sh.code = """
shader_type spatial;
render_mode unshaded, cull_disabled, shadows_disabled, depth_draw_never, blend_add;
void fragment() {
	// UV.y = 0 at the floor, 1 at the top of the barrier
	float h = UV.y;
	float bands = 0.5 + 0.5 * sin(h * 40.0 - TIME * 3.0);
	float grid = smoothstep(0.85, 1.0, sin(UV.x * 120.0) * 0.5 + 0.5) * 0.35;
	float base_glow = exp(-h * 6.0);
	float k = (0.12 + 0.16 * bands + grid * 0.5) * smoothstep(1.0, 0.55, h) + 1.3 * base_glow;
	ALBEDO = vec3(1.0, 0.13, 0.07) * k;
}
"""
	var sm := ShaderMaterial.new()
	sm.shader = sh
	return sm


# ---------------------------------------------------------------- merged static meshes

## Declares a batch: every primitive added to it ends up in ONE MeshInstance3D with one surface
## per material. layers = visual layers (2 = roof/ceiling, hidden from the minimap camera).
func batch_config(batch: String, layers := 1, shadow := true) -> void:
	if not _batches.has(batch):
		_batches[batch] = {"st": {}, "layers": layers, "shadow": shadow, "order": []}
	else:
		_batches[batch].layers = layers
		_batches[batch].shadow = shadow


func _st(batch: String, mat_key: String) -> SurfaceTool:
	if not _batches.has(batch):
		batch_config(batch)
	var b: Dictionary = _batches[batch]
	if not (b.st as Dictionary).has(mat_key):
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		b.st[mat_key] = st
		(b.order as Array).append(mat_key)
	return b.st[mat_key]


## One triangle facing `n` (the winding is fixed up so the front face points along n).
func tri(batch: String, mat_key: String, p: Array, uv: Array, n: Vector3) -> void:
	var st := _st(batch, mat_key)
	var a: Vector3 = p[0]
	var b: Vector3 = p[1]
	var c: Vector3 = p[2]
	var ua: Vector2 = uv[0]
	var ub: Vector2 = uv[1]
	var uc: Vector2 = uv[2]
	# Godot treats clockwise triangles as front faces: (c - a) x (b - a) must point along n.
	if (c - a).cross(b - a).dot(n) < 0.0:
		var t := b
		b = c
		c = t
		var tu := ub
		ub = uc
		uc = tu
	for v in [[a, ua], [b, ub], [c, uc]]:
		st.set_normal(n)
		st.set_uv(v[1])
		st.add_vertex(v[0])


## Quad p0..p3 (in order around the edge) facing n.
func quad(batch: String, mat_key: String, p: Array, uv: Array, n: Vector3) -> void:
	tri(batch, mat_key, [p[0], p[1], p[2]], [uv[0], uv[1], uv[2]], n)
	tri(batch, mat_key, [p[0], p[2], p[3]], [uv[0], uv[2], uv[3]], n)


## Box of `size` placed by xf (centre). UVs in metres along each face (multiplied by uv_k), so
## tiled textures keep their scale. skip: faces to leave out ("+x", "-x", "+y", "-y", "+z", "-z").
func box(batch: String, mat_key: String, size: Vector3, xf: Transform3D, uv_k := 1.0, skip: Array = []) -> void:
	var h := size * 0.5
	var faces := [
		["+x", Vector3.RIGHT, Vector3.BACK, Vector3.UP, h.x, h.z, h.y],
		["-x", Vector3.LEFT, Vector3.FORWARD, Vector3.UP, h.x, h.z, h.y],
		["+z", Vector3.BACK, Vector3.LEFT, Vector3.UP, h.z, h.x, h.y],
		["-z", Vector3.FORWARD, Vector3.RIGHT, Vector3.UP, h.z, h.x, h.y],
		["+y", Vector3.UP, Vector3.RIGHT, Vector3.FORWARD, h.y, h.x, h.z],
		["-y", Vector3.DOWN, Vector3.RIGHT, Vector3.BACK, h.y, h.x, h.z],
	]
	for f in faces:
		if skip.has(f[0]):
			continue
		var n: Vector3 = f[1]
		var u: Vector3 = f[2]
		var v: Vector3 = f[3]
		var d: float = f[4]
		var hu: float = f[5]
		var hv: float = f[6]
		var c := n * d
		var pts := [c - u * hu - v * hv, c + u * hu - v * hv, c + u * hu + v * hv, c - u * hu + v * hv]
		var wp := []
		for q: Vector3 in pts:
			wp.append(xf * q)
		var uvs := [Vector2(0, 2.0 * hv), Vector2(2.0 * hu, 2.0 * hv), Vector2(2.0 * hu, 0), Vector2(0, 0)]
		for i in 4:
			uvs[i] = uvs[i] * uv_k
		quad(batch, mat_key, wp, uvs, (xf.basis * n).normalized())


## Builds every declared batch into MeshInstance3D nodes under parent. Returns name -> node.
func build_batches(parent: Node3D) -> Dictionary:
	var out := {}
	for bname: String in _batches:
		var b: Dictionary = _batches[bname]
		if (b.order as Array).is_empty():
			continue
		var mesh := ArrayMesh.new()
		for key: String in b.order:
			var st: SurfaceTool = b.st[key]
			st.generate_tangents()
			st.commit(mesh)
			mesh.surface_set_material(mesh.get_surface_count() - 1, mat(key))
		var mi := MeshInstance3D.new()
		mi.name = "Batch_" + bname
		mi.mesh = mesh
		mi.layers = int(b.layers)
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if b.shadow else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		parent.add_child(mi)
		out[bname] = mi
	_batches.clear()
	return out


# ---------------------------------------------------------------- GLB props as MultiMeshes

func has_prop(file: String) -> bool:
	return not prop_parts(file).is_empty()


## Mesh parts of a prop GLB: [[Mesh, local Transform3D], ...]; [] when the file is missing.
func prop_parts(file: String) -> Array:
	if _parts.has(file):
		return _parts[file]
	var out := []
	var path := PROPS + file + ".glb"
	if ResourceLoader.exists(path):
		var ps: PackedScene = load(path)
		if ps:
			var root: Node = ps.instantiate()
			for mi in root.find_children("*", "MeshInstance3D", true, false):
				var m := mi as MeshInstance3D
				if m.mesh == null:
					continue
				var xf := Transform3D.IDENTITY
				var n: Node = m
				while n != null and n != root:
					if n is Node3D:
						xf = (n as Node3D).transform * xf
					n = n.get_parent()
				out.append([m.mesh, xf])
			root.free()
	_parts[file] = out
	return out


## Declares a prop set (one MultiMeshInstance3D per mesh part of the file).
## overrides: {material name (case-insensitive, exact match first, then "contains"): mat key}
## shadow: 0 off, 1 on. colors: per-instance colours (multiply the albedo of materials that use
## vertex colours, i.e. "paint" / "barrel_paint").
func set_config(set_name: String, file: String, overrides: Dictionary, shadow := 1, layers := 1, colors := false) -> void:
	if not _sets.has(set_name):
		_sets[set_name] = {"file": file, "xforms": [], "colors": [], "overrides": overrides, "shadow": shadow,
			"layers": layers, "colors_on": colors, "fallback": []}
		_set_order.append(set_name)


## Fallback geometry for a set whose GLB is missing: [[mat_key, size, centre], ...] boxes in the
## prop's own space (origin = the prop's origin).
func set_fallback(set_name: String, boxes: Array) -> void:
	_sets[set_name].fallback = boxes


func add(set_name: String, xf: Transform3D, color := Color.WHITE) -> void:
	var s: Dictionary = _sets[set_name]
	(s.xforms as Array).append(xf)
	(s.colors as Array).append(color)


func count(set_name: String) -> int:
	return (_sets[set_name].xforms as Array).size() if _sets.has(set_name) else 0


func _override_key(mname: String, overrides: Dictionary) -> String:
	var low := mname.to_lower()
	for key: String in overrides:
		if key.to_lower() == low:
			return String(overrides[key])
	for key: String in overrides:
		if low.contains(key.to_lower()):
			return String(overrides[key])
	return ""


func _fallback_mesh(boxes: Array) -> ArrayMesh:
	var mesh := ArrayMesh.new()
	var by_mat := {}
	var order := []
	for b in boxes:
		var key := String(b[0])
		if not by_mat.has(key):
			var st := SurfaceTool.new()
			st.begin(Mesh.PRIMITIVE_TRIANGLES)
			by_mat[key] = st
			order.append(key)
		var bm := BoxMesh.new()
		bm.size = b[1]
		(by_mat[key] as SurfaceTool).append_from(bm, 0, Transform3D(Basis.IDENTITY, b[2]))
	for key: String in order:
		var st: SurfaceTool = by_mat[key]
		st.commit(mesh)
		mesh.surface_set_material(mesh.get_surface_count() - 1, mat(key))
	return mesh


## Builds all declared prop sets under parent. Returns set name -> Array of MultiMeshInstance3D.
func build_sets(parent: Node3D) -> Dictionary:
	var out := {}
	for set_name in _set_order:
		var s: Dictionary = _sets[set_name]
		var xfs: Array = s.xforms
		if xfs.is_empty():
			continue
		var parts := prop_parts(String(s.file))
		var meshes := []          # [[Mesh, local xf], ...] with overridden materials
		if parts.is_empty():
			if (s.fallback as Array).is_empty():
				continue
			meshes.append([_fallback_mesh(s.fallback), Transform3D.IDENTITY])
		else:
			for p in parts:
				var src: Mesh = p[0]
				var mesh: Mesh = src.duplicate()
				for i in mesh.get_surface_count():
					var sm := src.surface_get_material(i)
					var key := _override_key(sm.resource_name if sm else "", s.overrides)
					if key != "" and mesh is ArrayMesh:
						(mesh as ArrayMesh).surface_set_material(i, mat(key))
				meshes.append([mesh, p[1]])
		var nodes := []
		for mp in meshes:
			var mm := MultiMesh.new()
			mm.transform_format = MultiMesh.TRANSFORM_3D
			mm.use_colors = bool(s.colors_on)
			mm.mesh = mp[0]
			mm.instance_count = xfs.size()
			var local: Transform3D = mp[1]
			for i in xfs.size():
				mm.set_instance_transform(i, (xfs[i] as Transform3D) * local)
				if s.colors_on:
					mm.set_instance_color(i, s.colors[i])
			var mmi := MultiMeshInstance3D.new()
			mmi.name = "Props_" + set_name
			mmi.multimesh = mm
			mmi.layers = int(s.layers)
			mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if int(s.shadow) == 1 else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			parent.add_child(mmi)
			nodes.append(mmi)
		out[set_name] = nodes
	return out
