class_name ShieldWall
extends StaticBody3D
## Deployable frozen-foam wall: blocks bullets, movement and line of sight until broken or expired.
## A curved slab of pale-blue ice foam (lumpy faces, rounded ends, a frosty white bloom at
## grazing angles), concave toward whoever put it down. The mesh is built once, in code.

const MAX_HP := 600.0
const LIFETIME := 45.0
const SIZE := Vector3(3.5, 2.0, 0.4)  # arc length, height, depth of the blocking volume
const BEND := 5.0                     # m: radius of the curve around the thrower (+Z side)
const THICK := 0.3                    # m: slab thickness
const LUMP := 0.045                   # m: height of the foam lumps on the faces
const FORM_TIME := 0.28               # s: the foam rises and sets

var hp := MAX_HP
var _life := LIFETIME
var _visual: MeshInstance3D
var _mat: ShaderMaterial
var _flash := 0.0
var _form := 0.0
static var _mesh: ArrayMesh
static var _shader: Shader
static var _ghost: ShaderMaterial


func _ready() -> void:
	collision_layer = Fighter.LAYER_SHIELD
	collision_mask = 0
	add_to_group("shield_walls")
	# Three boxes along the curve keep hits on the visible faces.
	var seg := SIZE.x / 3.0
	for k in 3:
		var phi := float(k - 1) * seg / BEND
		var cs := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = Vector3(seg + 0.06, SIZE.y, THICK + 0.06)
		cs.shape = box
		cs.position = Vector3(BEND * sin(phi), SIZE.y * 0.5, BEND * (1.0 - cos(phi)))
		cs.rotation.y = -phi
		add_child(cs)
	_visual = MeshInstance3D.new()
	_visual.mesh = wall_mesh()
	_mat = ice_material()
	_visual.material_override = _mat
	_visual.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_visual)
	_visual.scale = Vector3(1.0, 0.04, 1.0)
	create_tween().tween_property(_visual, "scale", Vector3.ONE, FORM_TIME) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_announce.call_deferred()             # whoever adds the wall places it right after


func _announce() -> void:
	Effects.shield_form(self, global_transform)
	Audio.play_at("shield_deploy", global_position, 0.0)


## The wall's mesh in its own space: base on y = 0, the middle of the curve at the origin, the
## ends bending toward +Z.
static func wall_mesh() -> ArrayMesh:
	if _mesh != null:
		return _mesh
	var noise := FastNoiseLite.new()
	noise.seed = 11
	noise.frequency = 1.1
	noise.fractal_octaves = 3
	var nu := 40          # columns along the wall
	var nf := 10          # rows up each face
	var nc := 7           # steps over the rounded top
	var ring := 2 * nf + nc + 1
	var back := nf + int(nc * 0.5)      # the ring's points past the top's middle are on the back
	var verts := PackedVector3Array()
	for i in nu + 1:
		var u := float(i) / nu
		var s := (u - 0.5) * SIZE.x                        # along the curve
		var e := minf(u, 1.0 - u) * SIZE.x                 # from the nearer end
		var round_end := clampf(e / 0.55, 0.0, 1.0)
		var top := SIZE.y * (0.95 + 0.05 * noise.get_noise_1d(s * 2.3)) * sqrt(1.0 - pow(1.0 - round_end, 2.0))
		var t := THICK * sqrt(round_end) * (1.0 + 0.12 * noise.get_noise_1d(s * 3.1 + 40.0))
		var face_top := maxf(top - t * 0.5, 0.0)
		for j in ring:
			var y := 0.0
			var z := 0.0                                     # + toward the thrower
			var out := Vector2.ZERO                          # outward (z, y) for the lumps
			if j <= nf:
				y = face_top * float(j) / nf
				z = t * 0.5
				out = Vector2(1, 0)
			elif j < nf + nc:
				var a := PI * float(j - nf) / nc
				y = face_top + t * 0.5 * sin(a)
				z = t * 0.5 * cos(a)
				out = Vector2(cos(a), sin(a))
			else:
				y = face_top * float(ring - 1 - j) / nf
				z = -t * 0.5
				out = Vector2(-1, 0)
			# Foam lumps, none at the ground line or the very ends (they stay closed).
			var keep := clampf(y / 0.25, 0.0, 1.0) * round_end
			var bump := noise.get_noise_3d(s * 1.6, y * 1.6, z * 4.0 + (7.0 if j > back else 0.0))
			z += out.x * LUMP * bump * keep
			y += out.y * LUMP * bump * keep
			var phi := s / BEND
			verts.append(Vector3((BEND - z) * sin(phi), y, BEND - (BEND - z) * cos(phi)))
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for v in verts:
		st.add_vertex(v)
	for i in nu:
		for j in ring - 1:              # clockwise seen from outside (Godot's front faces)
			var a := i * ring + j
			var b := (i + 1) * ring + j
			st.add_index(a)
			st.add_index(a + 1)
			st.add_index(b)
			st.add_index(a + 1)
			st.add_index(b + 1)
			st.add_index(b)
	st.generate_normals()
	_mesh = st.commit()
	return _mesh


## Pale ice: blue where it is seen face on, frosty white toward the edges and in the foam's
## folds, a faint cold glow; `flash` whitens it (forming, hits), `fade` lets it melt away.
static func ice_material() -> ShaderMaterial:
	if _shader == null:
		_shader = Shader.new()
		_shader.code = """
shader_type spatial;
render_mode blend_mix, depth_draw_always, cull_back, diffuse_burley, specular_schlick_ggx;
uniform vec3 ice : source_color = vec3(0.56, 0.80, 0.98);
uniform vec3 frost : source_color = vec3(0.93, 0.97, 1.0);
uniform float flash = 0.0;
uniform float fade = 1.0;
uniform float damage = 0.0;
varying vec3 lp;
float h(vec3 p) { return fract(sin(dot(p, vec3(127.1, 311.7, 74.7))) * 43758.5453); }
float vnoise(vec3 p) {
	vec3 i = floor(p);
	vec3 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(mix(h(i), h(i + vec3(1, 0, 0)), f.x), mix(h(i + vec3(0, 1, 0)), h(i + vec3(1, 1, 0)), f.x), f.y),
		mix(mix(h(i + vec3(0, 0, 1)), h(i + vec3(1, 0, 1)), f.x), mix(h(i + vec3(0, 1, 1)), h(i + vec3(1, 1, 1)), f.x), f.y), f.z);
}
void vertex() { lp = VERTEX; }
void fragment() {
	float n = vnoise(lp * 3.1) * 0.65 + vnoise(lp * 9.0) * 0.35;
	// frost crystals: the noise bumps the surface (screen-space derivatives, no texture)
	vec3 dpx = dFdx(VERTEX);
	vec3 dpy = dFdy(VERTEX);
	vec3 r1 = cross(dpy, NORMAL);
	vec3 r2 = cross(NORMAL, dpx);
	float det = dot(dpx, r1);
	vec3 grad = sign(det) * (dFdx(n) * r1 + dFdy(n) * r2);
	NORMAL = normalize(abs(det) * NORMAL - 0.06 * grad);
	float fres = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 2.2);
	float white = clamp(smoothstep(0.45, 0.85, n) * 0.7 + fres * 0.8 + flash, 0.0, 1.0);
	vec3 col = mix(ice, frost, white);
	col = mix(col, vec3(0.62, 0.70, 0.78), damage * 0.35 * smoothstep(0.3, 0.7, n));
	ALBEDO = col;
	ROUGHNESS = mix(0.18, 0.55, n);
	SPECULAR = 0.65;
	EMISSION = col * (0.16 + 0.9 * flash) + vec3(0.25, 0.55, 0.95) * fres * 0.3;
	ALPHA = clamp(0.86 + 0.14 * max(fres, white), 0.0, 1.0) * fade;
}
"""
	var m := ShaderMaterial.new()
	m.shader = _shader
	m.set_shader_parameter("flash", 1.0)
	return m


## The see-through preview of where a wall would stand (the player's wall in hand).
static func ghost_material() -> ShaderMaterial:
	if _ghost == null:
		var sh := Shader.new()
		sh.code = """
shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_back, shadows_disabled;
uniform vec3 tint : source_color = vec3(0.45, 0.85, 1.0);
void fragment() {
	float fres = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 1.6);
	float pulse = 0.85 + 0.15 * sin(TIME * 6.0);
	ALBEDO = tint * (0.18 + 0.9 * fres) * pulse;
}
"""
		_ghost = ShaderMaterial.new()
		_ghost.shader = sh
	return _ghost


## A wall mesh for the effects' shader warm-up (no collision, no sound).
static func warm_up_node() -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = wall_mesh()
	mi.material_override = ice_material()
	var g := MeshInstance3D.new()
	g.mesh = wall_mesh()
	g.material_override = ghost_material()
	mi.add_child(g)
	return mi


func take_bullet(damage: float, _from: Fighter = null) -> void:
	hp -= damage
	_flash = maxf(_flash, 0.55)
	if hp <= 0.0:
		_break()


func take_explosion(damage: float) -> void:
	take_bullet(damage)


func _break() -> void:
	if is_queued_for_deletion():
		return
	Effects.shield_break(self, global_position)
	Audio.play_at("shield_break", global_position, 0.0)
	queue_free()


func _process(delta: float) -> void:
	_life -= delta
	_form = minf(_form + delta / FORM_TIME, 1.0)
	_flash = maxf(_flash - delta * 4.0, 0.0)
	_mat.set_shader_parameter("flash", maxf(_flash, 1.0 - _form))
	_mat.set_shader_parameter("fade", clampf(_life / 1.5, 0.0, 1.0))
	_mat.set_shader_parameter("damage", 1.0 - hp / MAX_HP)
	if _life <= 0.0:
		queue_free()
