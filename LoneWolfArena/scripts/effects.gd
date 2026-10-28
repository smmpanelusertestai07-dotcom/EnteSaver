class_name Effects
extends RefCounted
## Lightweight visual effects (tracers, impacts, muzzle flashes, explosions).
## Everything is created on demand and frees itself.

const MAX_HOLES := 40

static var _mats := {}
static var _meshes := {}
static var _holes: Array = []
static var _hole_mat: StandardMaterial3D
static var muzzle_tex: Texture2D
static var glow_tex: Texture2D
static var lights_enabled := true


static func _mat(color: Color, additive := true, tex: Texture2D = null, billboard := false) -> StandardMaterial3D:
	var key := "%s|%s|%s|%s" % [color.to_html(), additive, tex.resource_path if tex else "", billboard]
	if _mats.has(key):
		return _mats[key]
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = color
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	if additive:
		m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	if tex:
		m.albedo_texture = tex
	if billboard:
		m.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
		m.billboard_keep_scale = true
	m.vertex_color_use_as_albedo = true
	_mats[key] = m
	return m


static func _box(size: Vector3) -> BoxMesh:
	var key := "box%s" % size
	if not _meshes.has(key):
		var b := BoxMesh.new()
		b.size = size
		_meshes[key] = b
	return _meshes[key]


static func _quad(size: Vector2) -> QuadMesh:
	var key := "quad%s" % size
	if not _meshes.has(key):
		var q := QuadMesh.new()
		q.size = size
		_meshes[key] = q
	return _meshes[key]


static func _scene(node: Node) -> Node:
	if node == null or not node.is_inside_tree():
		return null
	return node.get_tree().current_scene


static func _free_after(node: Node, seconds: float) -> void:
	node.get_tree().create_timer(seconds, false).timeout.connect(node.queue_free)


static func load_textures() -> void:
	if muzzle_tex == null and ResourceLoader.exists("res://assets/textures/muzzle_flash.png"):
		muzzle_tex = load("res://assets/textures/muzzle_flash.png")
	if glow_tex == null and ResourceLoader.exists("res://assets/textures/glow.png"):
		glow_tex = load("res://assets/textures/glow.png")


static func tracer(ctx: Node, from: Vector3, to: Vector3) -> void:
	var parent := _scene(ctx)
	if parent == null:
		return
	var dist := from.distance_to(to)
	if dist < 0.6:
		return
	var mi := MeshInstance3D.new()
	mi.mesh = _box(Vector3(0.022, 0.022, 1.0))
	mi.material_override = _mat(Color(1.0, 0.82, 0.42, 0.85))
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(mi)
	var dir := (to - from) / dist
	var up := Vector3.UP if absf(dir.y) < 0.98 else Vector3.RIGHT
	var b := Basis.looking_at(dir, up).scaled(Vector3(1, 1, dist * 0.85))
	mi.global_transform = Transform3D(b, from.lerp(to, 0.55))
	_free_after(mi, 0.045)


static func muzzle_flash(ctx: Node, pos: Vector3, dir: Vector3, big := false) -> void:
	var parent := _scene(ctx)
	if parent == null:
		return
	load_textures()
	var mi := MeshInstance3D.new()
	var s := 0.55 if big else 0.36
	mi.mesh = _quad(Vector2(s, s))
	if muzzle_tex:
		mi.material_override = _mat(Color(1, 0.9, 0.7, 1), true, muzzle_tex, true)
	else:
		mi.material_override = _mat(Color(1.0, 0.75, 0.3, 0.9), true, null, true)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(mi)
	mi.global_position = pos + dir * 0.08
	mi.rotate_object_local(Vector3.FORWARD, randf() * TAU)
	_free_after(mi, 0.05)
	if lights_enabled:
		var l := OmniLight3D.new()
		l.light_color = Color(1.0, 0.75, 0.4)
		l.light_energy = 2.2 if big else 1.4
		l.omni_range = 4.0
		l.shadow_enabled = false
		parent.add_child(l)
		l.global_position = pos
		_free_after(l, 0.05)


static func _burst(parent: Node, pos: Vector3, normal: Vector3, color: Color, amount: int, speed: float, size: float, life: float, gravity := -9.0) -> void:
	var p := CPUParticles3D.new()
	p.one_shot = true
	p.explosiveness = 1.0
	p.amount = amount
	p.lifetime = life
	p.local_coords = false
	p.mesh = _box(Vector3(size, size, size * 3.0))
	p.material_override = _mat(color)
	p.direction = normal
	p.spread = 55.0
	p.initial_velocity_min = speed * 0.5
	p.initial_velocity_max = speed
	p.gravity = Vector3(0, gravity, 0)
	p.scale_amount_min = 0.6
	p.scale_amount_max = 1.2
	p.particle_flag_align_y = true
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(p)
	p.global_position = pos
	p.emitting = true
	_free_after(p, life + 0.2)


static func impact(ctx: Node, pos: Vector3, normal: Vector3) -> void:
	var parent := _scene(ctx)
	if parent == null:
		return
	_burst(parent, pos + normal * 0.02, normal, Color(1.0, 0.75, 0.35, 1), 7, 5.0, 0.025, 0.22)
	_burst(parent, pos + normal * 0.05, normal, Color(0.55, 0.52, 0.48, 0.55), 4, 1.2, 0.09, 0.45, 0.5)
	var hole := MeshInstance3D.new()
	hole.mesh = _quad(Vector2(0.07, 0.07))
	hole.material_override = _hole_material()
	hole.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(hole)
	var up := Vector3.UP if absf(normal.y) < 0.95 else Vector3.RIGHT
	hole.global_transform = Transform3D(Basis.looking_at(-normal, up), pos + normal * 0.012)
	_holes.append(hole)
	while _holes.size() > MAX_HOLES:
		var old: Variant = _holes.pop_front()
		if is_instance_valid(old):
			(old as Node).queue_free()
	_free_after(hole, 12.0)


## Bullet hole: a dark round core with a soft edge and a faint chipped rim, lit like the surface
## it sits on (texture drawn once).
static func _hole_material() -> StandardMaterial3D:
	if _hole_mat != null:
		return _hole_mat
	var n := 64
	var img := Image.create_empty(n, n, false, Image.FORMAT_RGBA8)
	for y in n:
		for x in n:
			var r := Vector2(x + 0.5 - n * 0.5, y + 0.5 - n * 0.5).length() / (n * 0.5)
			var c := Color(0.03, 0.028, 0.025).lerp(Color(0.34, 0.31, 0.27), clampf((r - 0.3) / 0.25, 0.0, 1.0))
			c.a = maxf((1.0 - smoothstep(0.26, 0.4, r)) * 0.95, (1.0 - smoothstep(0.4, 0.95, r)) * 0.35)
			img.set_pixel(x, y, c)
	img.generate_mipmaps()
	var m := StandardMaterial3D.new()
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.albedo_texture = ImageTexture.create_from_image(img)
	m.roughness = 1.0
	_hole_mat = m
	return m


static func hit_spark(ctx: Node, pos: Vector3, normal: Vector3, headshot: bool) -> void:
	var parent := _scene(ctx)
	if parent == null:
		return
	var c := Color(1.0, 0.25, 0.2, 1) if not headshot else Color(1.0, 0.9, 0.3, 1)
	_burst(parent, pos, normal, c, 10 if headshot else 6, 3.5, 0.03, 0.25)


static func shield_hit(ctx: Node, pos: Vector3, normal: Vector3) -> void:
	var parent := _scene(ctx)
	if parent == null:
		return
	_burst(parent, pos, normal, Color(0.4, 0.95, 1.0, 1), 8, 3.0, 0.03, 0.3, -2.0)


static func shield_break(ctx: Node, pos: Vector3) -> void:
	var parent := _scene(ctx)
	if parent == null:
		return
	_burst(parent, pos + Vector3.UP, Vector3.UP, Color(0.5, 0.95, 1.0, 1), 40, 6.0, 0.06, 0.8)


static func explosion(ctx: Node, pos: Vector3) -> void:
	var parent := _scene(ctx)
	if parent == null:
		return
	_burst(parent, pos, Vector3.UP, Color(1.0, 0.6, 0.15, 1), 40, 11.0, 0.12, 0.55, -4.0)
	_burst(parent, pos, Vector3.UP, Color(1.0, 0.85, 0.4, 1), 20, 6.0, 0.25, 0.3, 0.0)
	_burst(parent, pos + Vector3.UP * 0.3, Vector3.UP, Color(0.25, 0.23, 0.22, 0.6), 18, 2.5, 0.6, 1.6, 1.0)
	var ball := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 0.5
	sm.height = 1.0
	ball.mesh = sm
	ball.material_override = _mat(Color(1.0, 0.7, 0.3, 0.7))
	ball.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(ball)
	ball.global_position = pos
	var tw := ball.create_tween()
	tw.tween_property(ball, "scale", Vector3.ONE * 7.0, 0.25)
	tw.parallel().tween_property(ball, "transparency", 1.0, 0.25)
	tw.tween_callback(ball.queue_free)
	if lights_enabled:
		var l := OmniLight3D.new()
		l.light_color = Color(1.0, 0.65, 0.3)
		l.light_energy = 6.0
		l.omni_range = 12.0
		parent.add_child(l)
		l.global_position = pos + Vector3.UP
		var tl := l.create_tween()
		tl.tween_property(l, "light_energy", 0.0, 0.4)
		tl.tween_callback(l.queue_free)


## Spawns every effect once far below the floor so their shaders compile during the prep
## phase instead of stuttering on the first shot/explosion.
static func warm_up(ctx: Node) -> void:
	load_textures()
	var p := Vector3(0, -50, 0)
	tracer(ctx, p, p + Vector3(0, 0, -5))
	muzzle_flash(ctx, p, Vector3.FORWARD, false)
	muzzle_flash(ctx, p, Vector3.FORWARD, true)
	impact(ctx, p, Vector3.UP)
	hit_spark(ctx, p, Vector3.UP, false)
	hit_spark(ctx, p, Vector3.UP, true)
	shield_hit(ctx, p, Vector3.UP)
	shield_break(ctx, p)
	explosion(ctx, p)
